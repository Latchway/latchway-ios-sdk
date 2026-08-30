import Foundation
import SwiftOpenAI
import Testing
@testable import Latchway
@testable import LatchwaySwiftOpenAI

@Test func pinnedSwiftOpenAIVersionAndPlaceholderAreExplicit() {
    #expect(LatchwaySwiftOpenAIHTTPClient.testedFrameworkVersion == "4.6.0")
    #expect(LatchwayFeatureTransport.placeholderAPIKey == "latchway-managed")
}

@Test func swiftOpenAIHTTPShapesRemainAvailable() {
    let request = HTTPRequest(
        url: URL(string: "https://gateway.example.test/v1/responses")!,
        method: .post,
        headers: ["Content-Type": "application/json"],
        body: Data("{}".utf8)
    )
    #expect(request.method == .post)
    #expect(request.body == Data("{}".utf8))
    let response = HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
    #expect(response.statusCode == 200)
}

@Test func bufferedRequestUsesInjectedSwiftOpenAITransportWithoutCredentialExport() async throws {
    let recorder = SwiftOpenAIRequestRecorder()
    let transport = LatchwayFeatureTransport(
        feature: "habit-assistant",
        framework: .swiftOpenAI(version: "4.6.0"),
        baseURL: URL(string: "https://gateway.example.test")!,
        authorize: { request in request },
        send: { request in
            await recorder.record(request)
            return LatchwayHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"id":"response_1"}"#.utf8)
            )
        }
    )
    let adapter = LatchwaySwiftOpenAIHTTPClient(transport: transport)
    _ = try adapter.makeService()
    let body = Data(#"{"input":"hello"}"#.utf8)
    let request = HTTPRequest(
        url: URL(string: "https://gateway.example.test/v1/responses")!,
        method: .post,
        headers: ["Content-Type": "application/json"],
        body: body
    )

    let (data, response) = try await adapter.data(for: request)

    #expect(response.statusCode == 200)
    #expect(data == Data(#"{"id":"response_1"}"#.utf8))
    let captured = try #require(await recorder.lastRequest)
    #expect(captured.httpMethod == "POST")
    #expect(captured.httpBody == body)
    #expect(captured.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(captured.value(forHTTPHeaderField: "api-key") == nil)
}

@Test func serviceFactoryPreservesGatewayBasePath() async throws {
    let recorder = SwiftOpenAIRequestRecorder()
    let transport = LatchwayFeatureTransport(
        feature: "habit-assistant",
        framework: .swiftOpenAI(version: "4.6.0"),
        baseURL: URL(string: "https://gateway.example.test/latchway")!,
        authorize: { request in request },
        send: { request in
            await recorder.record(request)
            return LatchwayHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data("{}".utf8)
            )
        }
    )
    let service = try LatchwaySwiftOpenAIHTTPClient(transport: transport).makeService()

    do {
        _ = try await service.responseCreate(.init(
            input: .string("hello"),
            model: .gpt4o
        ))
        Issue.record("The intentionally incomplete response should not decode")
    } catch {}

    let captured = try #require(await recorder.lastRequest)
    #expect(captured.url?.absoluteString == "https://gateway.example.test/latchway/v1/responses")
    #expect(
        captured.value(forHTTPHeaderField: "Authorization")
            == "Bearer \(LatchwayFeatureTransport.placeholderAPIKey)"
    )
}

@Test func streamingAdapterPreservesEveryLineWithBoundedBuffering() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SwiftOpenAIStreamingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let transport = LatchwayFeatureTransport(
        feature: "habit-assistant",
        framework: .swiftOpenAI(version: "4.6.0"),
        baseURL: URL(string: "https://gateway.example.test")!,
        session: session,
        authorize: { request in request },
        send: { _ in throw LatchwayError.transportFailure }
    )
    let adapter = LatchwaySwiftOpenAIHTTPClient(transport: transport)
    let request = HTTPRequest(
        url: URL(string: "https://gateway.example.test/v1/responses")!,
        method: .post,
        headers: [:],
        body: Data()
    )

    let (stream, response) = try await adapter.bytes(for: request)
    #expect(response.statusCode == 200)
    guard case let .lines(lines) = stream else {
        Issue.record("SwiftOpenAI must receive its native line stream")
        return
    }
    var received: [String] = []
    for try await line in lines {
        received.append(line)
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(received == (0 ..< 64).map { "data: line-\($0)" })
}

private actor SwiftOpenAIRequestRecorder {
    private(set) var lastRequest: URLRequest?

    func record(_ request: URLRequest) {
        lastRequest = request
    }
}

private final class SwiftOpenAIStreamingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gateway.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = (0 ..< 64).map { "data: line-\($0)\n" }.joined()
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
