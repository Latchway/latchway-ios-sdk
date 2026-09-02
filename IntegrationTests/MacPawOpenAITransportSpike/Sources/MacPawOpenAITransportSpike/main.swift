import Foundation
import OpenAI
#if canImport(Darwin)
import Darwin
#endif

private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var cancellationStopPaths: [String] = []

    func record(_ request: URLRequest) {
        lock.lock()
        paths.append(request.url?.path ?? "<missing>")
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func recordStop(_ request: URLRequest) {
        guard request.value(forHTTPHeaderField: ProbeURLProtocol.markerHeader)
            == "patched-cancellation"
        else { return }
        lock.lock()
        cancellationStopPaths.append(request.url?.path ?? "<missing>")
        lock.unlock()
    }

    func cancellationStopSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return cancellationStopPaths
    }
}

private final class ProbeURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = ProbeState()
    static let markerHeader = "X-Latchway-MacPaw-Transport-Probe"

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: markerHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.value(forHTTPHeaderField: Self.markerHeader) == "patched-cancellation" {
            return
        }
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.state.recordStop(request)
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    private let condition = NSCondition()
    private let descriptor: Int32
    private let expectedRequests: Int
    private var paths: [String] = []

    let port: Int

    init(expectedRequests: Int) throws {
        guard expectedRequests > 0 else {
            throw SpikeFailure("loopback server requires at least one request")
        }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SpikeFailure("loopback socket creation failed: \(errno)")
        }
        self.descriptor = descriptor
        self.expectedRequests = expectedRequests

        var reuse: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout.size(ofValue: reuse))
        ) == 0 else {
            Darwin.close(descriptor)
            throw SpikeFailure("loopback socket configuration failed: \(errno)")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, Int32(expectedRequests)) == 0 else {
            Darwin.close(descriptor)
            throw SpikeFailure("loopback socket bind/listen failed: \(errno)")
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw SpikeFailure("loopback socket name lookup failed: \(errno)")
        }
        port = Int(UInt16(bigEndian: bound.sin_port))

        Thread { [weak self] in self?.serve() }.start()
    }

    deinit {
        Darwin.close(descriptor)
    }

    func waitForPaths(timeout: TimeInterval) -> [String]? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while paths.count < expectedRequests {
            if !condition.wait(until: deadline) {
                return nil
            }
        }
        return paths
    }

    private func serve() {
        for _ in 0 ..< expectedRequests {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { return }

            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while request.count < 64 * 1024 {
                let count = Darwin.read(client, &buffer, buffer.count)
                if count <= 0 { break }
                request.append(contentsOf: buffer.prefix(Int(count)))
                if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            }
            let firstLine = String(decoding: request, as: UTF8.self)
                .split(separator: "\r\n", maxSplits: 1)
                .first?
                .split(separator: " ")
            let path = firstLine?.count == 3 ? String(firstLine![1]) : "<invalid>"
            condition.lock()
            paths.append(path)
            condition.broadcast()
            condition.unlock()

            let response = Data(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                    .appending("Content-Length: 0\r\nConnection: close\r\n\r\n")
                    .utf8
            )
            response.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(client, base.advanced(by: written), bytes.count - written)
                    if count <= 0 { return }
                    written += count
                }
            }
            Darwin.close(client)
        }
    }
}

@main
private enum MacPawOpenAITransportSpike {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let expectsInjectedStreaming: Bool
        switch arguments {
        case []:
            expectsInjectedStreaming = false
        case ["--expect-injected-streaming"]:
            expectsInjectedStreaming = true
        default:
            throw SpikeFailure("unsupported arguments: \(arguments)")
        }
        let registeredGlobally: Bool
        if expectsInjectedStreaming {
            registeredGlobally = false
        } else {
            guard URLProtocol.registerClass(ProbeURLProtocol.self) else {
                throw SpikeFailure("URLProtocol class registration failed")
            }
            registeredGlobally = true
        }
        defer {
            if registeredGlobally {
                URLProtocol.unregisterClass(ProbeURLProtocol.self)
            }
        }

        let injectedConfiguration = URLSessionConfiguration.ephemeral
        injectedConfiguration.protocolClasses = [ProbeURLProtocol.self]
        let injectedSession = URLSession(configuration: injectedConfiguration)
        defer { injectedSession.invalidateAndCancel() }

        let loopback = try LoopbackHTTPServer(expectedRequests: 2)
        let configuration = OpenAI.Configuration(
            token: nil,
            host: "127.0.0.1",
            port: loopback.port,
            scheme: "http",
            basePath: "/v1",
            timeoutInterval: 1,
            customHeaders: [
                ProbeURLProtocol.markerHeader: expectsInjectedStreaming
                    ? "patched-configuration"
                    : "stock-0.5.1",
            ]
        )
        let openAI = OpenAI(configuration: configuration, session: injectedSession)
        let chatQuery = ChatQuery(
            messages: [.user(.init(content: .string("transport probe")))],
            model: .gpt4_o
        )
        let responseQuery = CreateModelResponseQuery(
            input: .textInput("transport probe"),
            model: "gpt-4o"
        )
        let streamingResponseQuery = CreateModelResponseQuery(
            input: .textInput("transport probe"),
            model: "gpt-4o",
            stream: true
        )

        do {
            _ = try await openAI.chats(query: chatQuery)
        } catch {
            // The deliberately minimal JSON body is not a ChatResult. Dispatch
            // interception, recorded below, is the property under test.
        }
        do {
            _ = try await openAI.responses.createResponse(query: responseQuery)
        } catch {
            // The deliberately minimal JSON body is not a ResponseObject.
        }
        let afterOrdinary = ProbeURLProtocol.state.snapshot()
        guard afterOrdinary == ["/v1/chat/completions", "/v1/responses"] else {
            throw SpikeFailure(
                "the public injected URLSession did not cover both ordinary requests: \(afterOrdinary)"
            )
        }

        do {
            for try await _ in openAI.chatsStream(query: chatQuery) {}
        } catch {
            // Stock 0.5.1 creates a separate URLSession(configuration: .default)
            // here. A decoding failure is acceptable only after the loopback
            // listener below proves that this path really dispatched.
        }
        do {
            for try await _ in openAI.responses.createResponseStreaming(
                query: streamingResponseQuery
            ) {}
        } catch {
            // Responses streaming is routed through the same inaccessible
            // streaming factory and therefore has the same bypass.
        }
        let afterStreaming = ProbeURLProtocol.state.snapshot()
        if expectsInjectedStreaming {
            let expected = [
                "/v1/chat/completions", "/v1/responses",
                "/v1/chat/completions", "/v1/responses",
            ]
            guard afterStreaming == expected else {
                throw SpikeFailure(
                    "patched streaming did not reuse the injected URLSession configuration: \(afterStreaming)"
                )
            }

            let cancellationConfiguration = OpenAI.Configuration(
                token: nil,
                host: "127.0.0.1",
                port: loopback.port,
                scheme: "http",
                basePath: "/v1",
                timeoutInterval: 30,
                customHeaders: [ProbeURLProtocol.markerHeader: "patched-cancellation"]
            )
            let cancellationClient = OpenAI(
                configuration: cancellationConfiguration,
                session: injectedSession
            )
            let cancellationTask = Task {
                for try await _ in cancellationClient.chatsStream(query: chatQuery) {}
            }
            try await waitUntil {
                ProbeURLProtocol.state.snapshot().count == expected.count + 1
            }
            cancellationTask.cancel()
            try await waitUntil {
                ProbeURLProtocol.state.cancellationStopSnapshot()
                    == ["/v1/chat/completions"]
            }
            _ = await cancellationTask.result

            print("ordinary Chat Completions + Responses interception: covered")
            print("streaming Chat Completions + Responses interception: covered")
            print("stream cancellation reaches injected URLProtocol: covered")
            print("MacPaw/OpenAI patched transport injection seam: READY FOR ADAPTER CONFORMANCE")
        } else {
            guard let streamingPaths = loopback.waitForPaths(timeout: 5),
                  streamingPaths == ["/v1/chat/completions", "/v1/responses"]
            else {
                throw SpikeFailure(
                    "both stock streams must bypass URLProtocol and reach the isolated loopback listener"
                )
            }
            guard afterStreaming == afterOrdinary else {
                throw SpikeFailure(
                    "stock streaming unexpectedly reached the injected/global URLProtocol: \(afterStreaming)"
                )
            }

            print("ordinary Chat Completions + Responses interception: covered")
            print("streaming Chat Completions + Responses interception: unavailable")
            print("MacPaw/OpenAI 0.5.1 full Latchway transport: BLOCKED")
        }
    }

    private static func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            guard Date() < deadline else {
                throw SpikeFailure(
                    "timed out waiting for the injected transport; requests="
                        + "\(ProbeURLProtocol.state.snapshot()), stops="
                        + "\(ProbeURLProtocol.state.cancellationStopSnapshot())"
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct SpikeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
