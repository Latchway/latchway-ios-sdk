import Foundation
import OpenAI
#if canImport(Darwin)
import Darwin
#endif

private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

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
}

private final class ProbeURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = ProbeState()
    static let markerHeader = "X-Latchway-MacPaw-Transport-Probe"

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: markerHeader) == "stock-0.5.1"
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
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
        guard URLProtocol.registerClass(ProbeURLProtocol.self) else {
            throw SpikeFailure("URLProtocol class registration failed")
        }
        defer { URLProtocol.unregisterClass(ProbeURLProtocol.self) }

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
            customHeaders: [ProbeURLProtocol.markerHeader: "stock-0.5.1"]
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
        guard let streamingPaths = loopback.waitForPaths(timeout: 5),
              streamingPaths == ["/v1/chat/completions", "/v1/responses"]
        else {
            throw SpikeFailure(
                "both stock streams must bypass URLProtocol and reach the isolated loopback listener"
            )
        }
        let afterStreaming = ProbeURLProtocol.state.snapshot()
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

private struct SpikeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
