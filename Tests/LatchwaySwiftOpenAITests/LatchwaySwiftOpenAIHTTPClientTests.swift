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

// FW-REQ-106 limitation evidence: SwiftOpenAI 4.6.0 exposes no timeout or
// deadline member for this adapter to propagate. This is intentionally not a
// passing conformance claim until the upstream HTTPRequest surface adds one.
@Test func fwREQ106PinnedSwiftOpenAIRequestSurfaceCannotExpressTimeout() {
    let request = HTTPRequest(
        url: URL(string: "https://gateway.example.test/v1/responses")!,
        method: .post,
        headers: [:]
    )
    let fields = Set(Mirror(reflecting: request).children.compactMap(\.label))

    #expect(fields == ["url", "method", "headers", "body"])
}

// FW-REQ-104
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
        headers: [
            "Content-Type": "application/json",
            "X-Application-Correlation-ID": "correlation-123",
        ],
        body: body
    )

    let (data, response) = try await adapter.data(for: request)

    #expect(response.statusCode == 200)
    #expect(data == Data(#"{"id":"response_1"}"#.utf8))
    let captured = try #require(await recorder.lastRequest)
    #expect(captured.httpMethod == "POST")
    #expect(captured.httpBody == body)
    #expect(captured.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(
        captured.value(forHTTPHeaderField: "X-Application-Correlation-ID")
            == "correlation-123"
    )
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

// FW-BEH-105, FW-BEH-106
@Test func fwBEH105And106OfficialServiceMapsQuotaWithRequestIDAndRemediation() async throws {
    let requestID = "request-swift-openai-quota-12345678"
    let documentationURL = "https://docs.latchway.dev/errors/quota-exceeded"
    let problem = try JSONSerialization.data(withJSONObject: [
        "type": documentationURL,
        "documentation_url": documentationURL,
        "title": "Quota exceeded",
        "status": 429,
        "detail": "The feature quota is exhausted.",
        "code": "quota_exceeded",
        "request_id": requestID,
        "retryable": false,
    ], options: [.sortedKeys])
    let transport = LatchwayFeatureTransport(
        feature: "habit-assistant",
        framework: .swiftOpenAI(version: "4.6.0"),
        baseURL: URL(string: "https://gateway.example.test")!,
        authorize: { request in request },
        send: { _ in
            LatchwayHTTPResponse(
                statusCode: 429,
                headers: [
                    "Content-Type": "application/problem+json",
                    "X-Latchway-Request-ID": requestID,
                ],
                body: problem
            )
        }
    )
    let service = try LatchwaySwiftOpenAIHTTPClient(transport: transport).makeService()

    do {
        _ = try await service.responseCreate(.init(input: .string("hello"), model: .gpt4o))
        Issue.record("HTTP 429 must remain an actionable SwiftOpenAI error")
    } catch let error as APIError {
        guard case let .responseUnsuccessful(description, statusCode) = error else {
            Issue.record("Unexpected SwiftOpenAI error: \(error)")
            return
        }
        #expect(statusCode == 429)
        #expect(description.contains("quota_exceeded"))
        #expect(description.contains(requestID))
        #expect(description.contains(documentationURL))
    }
}

// FW-BEH-107
@Test func fwBEH107FrameworkDebugBoundaryCannotObserveNativeTokens() async throws {
    let frameworkRecorder = SwiftOpenAIRequestRecorder()
    let nativeRecorder = SwiftOpenAIRequestRecorder()
    let accessToken = "access-token-that-must-remain-inside-the-native-transport"
    let refreshToken = "refresh-token-that-must-never-enter-a-framework-request"
    let proof = "dpop-proof-created-immediately-before-native-dispatch"
    let transport = LatchwayFeatureTransport(
        feature: "habit-assistant",
        framework: .swiftOpenAI(version: "4.6.0"),
        baseURL: URL(string: "https://gateway.example.test")!,
        authorize: { request in request },
        send: { request in
            // SwiftOpenAI performs its optional debug logging before this
            // HTTPClient boundary. Native credentials are attached only after
            // that boundary in the real Latchway transport.
            await frameworkRecorder.record(request)
            var authorized = request
            authorized.setValue("DPoP \(accessToken)", forHTTPHeaderField: "Authorization")
            authorized.setValue(proof, forHTTPHeaderField: "DPoP")
            await nativeRecorder.record(authorized)
            return LatchwayHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data("{}".utf8)
            )
        }
    )
    let service = try LatchwaySwiftOpenAIHTTPClient(transport: transport)
        .makeService(debugEnabled: true)

    do {
        _ = try await service.responseCreate(.init(input: .string("hello"), model: .gpt4o))
    } catch {
        // The deliberately incomplete fixture only needs to cross the debug
        // logging and HTTPClient boundary; successful model decoding is not
        // part of this redaction assertion.
    }

    let frameworkRequest = try #require(await frameworkRecorder.lastRequest)
    let frameworkVisible = [
        frameworkRequest.allHTTPHeaderFields?.description ?? "",
        frameworkRequest.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "",
    ].joined(separator: "\n")
    #expect(!frameworkVisible.contains(accessToken))
    #expect(!frameworkVisible.contains(refreshToken))
    #expect(!frameworkVisible.contains(proof))
    #expect(frameworkRequest.value(forHTTPHeaderField: "DPoP") == nil)

    let nativeRequest = try #require(await nativeRecorder.lastRequest)
    #expect(nativeRequest.value(forHTTPHeaderField: "Authorization") == "DPoP \(accessToken)")
    #expect(nativeRequest.value(forHTTPHeaderField: "DPoP") == proof)
}

@Test func officialServicePreservesChatToolsStructuredOutputAndEmbeddings() async throws {
    let recorder = SwiftOpenAIRequestRecorder()
    let transport = LatchwayFeatureTransport(
        feature: "habit-assistant",
        framework: .swiftOpenAI(version: "4.6.0"),
        baseURL: URL(string: "https://gateway.example.test")!,
        authorize: { request in request },
        send: { request in
            await recorder.record(request)
            let body: String
            switch request.url?.path {
            case "/v1/chat/completions":
                body = #"{"id":"chatcmpl_latchway","object":"chat.completion","created":1,"model":"gpt-4o","choices":[{"index":0,"message":{"role":"assistant","content":"{\"answer\":\"ok\"}"},"finish_reason":"stop"}]}"#
            case "/v1/embeddings":
                body = #"{"object":"list","data":[{"object":"embedding","embedding":[0.25,0.75],"index":0}],"model":"text-embedding-3-small","usage":{"prompt_tokens":1,"total_tokens":1}}"#
            default:
                body = #"{"error":"unexpected path"}"#
            }
            return LatchwayHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(body.utf8)
            )
        }
    )
    let service = try LatchwaySwiftOpenAIHTTPClient(transport: transport).makeService()
    let schema = JSONSchema(
        type: .object,
        properties: ["answer": JSONSchema(type: .string)],
        required: ["answer"]
    )

    let chat = try await service.startChat(parameters: .init(
        messages: [.init(role: .user, content: .text("Return JSON"))],
        model: .gpt4o,
        tools: [.init(function: .init(
            name: "fixture_lookup",
            strict: true,
            description: "Returns fixture data",
            parameters: schema
        ))],
        responseFormat: .jsonSchema(.init(name: "fixture_answer", strict: true, schema: schema))
    ))
    let embeddings = try await service.createEmbeddings(parameters: .init(
        input: "hello",
        model: .textEmbedding3Small,
        encodingFormat: "float",
        dimensions: 2
    ))

    #expect(chat.id == "chatcmpl_latchway")
    #expect(embeddings.data.first?.embedding == [0.25, 0.75])
    let requests = await recorder.requests
    #expect(requests.map { $0.url?.path } == ["/v1/chat/completions", "/v1/embeddings"])
    let chatData = try #require(requests[0].httpBody)
    let chatBody = try #require(
        JSONSerialization.jsonObject(with: chatData) as? [String: Any]
    )
    #expect((chatBody["tools"] as? [[String: Any]])?.count == 1)
    #expect((chatBody["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
    let embeddingData = try #require(requests[1].httpBody)
    let embeddingBody = try #require(
        JSONSerialization.jsonObject(with: embeddingData) as? [String: Any]
    )
    #expect(embeddingBody["input"] as? String == "hello")
    #expect(embeddingBody["dimensions"] as? Int == 2)
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

// FW-REQ-109
@Test func officialServiceDecodesStreamingChatThroughInjectedByteTransport() async throws {
    let recorder = SwiftOpenAIRequestRecorder()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SwiftOpenAIOfficialStreamingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let transport = LatchwayFeatureTransport(
        feature: "habit-assistant",
        framework: .swiftOpenAI(version: "4.6.0"),
        baseURL: URL(string: "https://gateway.example.test")!,
        session: session,
        authorize: { request in
            await recorder.record(request)
            return request
        },
        send: { _ in throw LatchwayError.transportFailure }
    )
    let service = try LatchwaySwiftOpenAIHTTPClient(transport: transport).makeService()

    let stream = try await service.startStreamedChat(parameters: .init(
        messages: [.init(role: .user, content: .text("Stream one word"))],
        model: .gpt4o,
        streamOptions: .init(includeUsage: true)
    ))
    var received = ""
    var finalUsage: ChatUsage?
    for try await chunk in stream {
        received += chunk.choices?.first?.delta?.content ?? ""
        finalUsage = chunk.usage ?? finalUsage
    }

    #expect(received == "hello")
    #expect(finalUsage?.promptTokens == 7)
    #expect(finalUsage?.completionTokens == 2)
    #expect(finalUsage?.totalTokens == 9)
    #expect(finalUsage?.promptTokensDetails?.cachedTokens == 3)
    #expect(finalUsage?.completionTokensDetails?.reasoningTokens == 1)
    let body = try #require(await recorder.lastRequest?.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let streamOptions = try #require(object["stream_options"] as? [String: Any])
    #expect(streamOptions["include_usage"] as? Bool == true)
}

// FW-REQ-105
@Test func cancellingOfficialStreamConsumerStopsUnderlyingNativeLoad() async throws {
    SwiftOpenAICancellableStreamingURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SwiftOpenAICancellableStreamingURLProtocol.self]
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
    let service = try LatchwaySwiftOpenAIHTTPClient(transport: transport).makeService()
    let stream = try await service.startStreamedChat(parameters: .init(
        messages: [.init(role: .user, content: .text("Wait after one chunk"))],
        model: .gpt4o
    ))
    let received = SwiftOpenAIChunkCounter()
    let consumer = Task {
        for try await _ in stream {
            await received.record()
        }
    }
    try await waitUntilSwiftOpenAI { await received.count > 0 }

    consumer.cancel()
    do {
        try await consumer.value
    } catch is CancellationError {
        // AsyncThrowingStream may preserve structured cancellation directly.
    } catch let error as LatchwayError {
        #expect(error == .cancelled)
    }
    try await waitUntilSwiftOpenAI {
        SwiftOpenAICancellableStreamingURLProtocol.snapshot().stopCount > 0
    }

    let snapshot = SwiftOpenAICancellableStreamingURLProtocol.snapshot()
    #expect(snapshot.requestCount == 1)
    #expect(snapshot.stopCount == 1)
}

private actor SwiftOpenAIRequestRecorder {
    private(set) var lastRequest: URLRequest?
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lastRequest = request
        requests.append(request)
    }
}

private actor SwiftOpenAIChunkCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private func waitUntilSwiftOpenAI(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else { throw SwiftOpenAITestError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum SwiftOpenAITestError: Error {
    case timedOut
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

private final class SwiftOpenAIOfficialStreamingURLProtocol: URLProtocol {
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
        let content = #"data: {"id":"chatcmpl_latchway","object":"chat.completion.chunk","created":1,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"hello"},"finish_reason":null}],"usage":null}"#
        let usage = #"data: {"id":"chatcmpl_latchway","object":"chat.completion.chunk","created":1,"model":"gpt-4o","choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2,"total_tokens":9,"prompt_tokens_details":{"cached_tokens":3},"completion_tokens_details":{"reasoning_tokens":1}}}"#
        let body = content + "\n\n" + usage + "\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SwiftOpenAICancellableStreamingURLProtocol: URLProtocol {
    struct Snapshot: Sendable {
        let requestCount: Int
        let stopCount: Int
    }

    private static let state = State()

    static func reset() {
        state.reset()
    }

    static func snapshot() -> Snapshot {
        state.snapshot()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gateway.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.recordRequest()
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
        let body = #"data: {"id":"chatcmpl_latchway","object":"chat.completion.chunk","created":1,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"hello"},"finish_reason":null}]}"#
            + "\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        // The response intentionally remains open until consumer cancellation.
    }

    override func stopLoading() {
        Self.state.recordStop()
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var requestCount = 0
        private var stopCount = 0

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            requestCount = 0
            stopCount = 0
        }

        func recordRequest() {
            lock.lock()
            defer { lock.unlock() }
            requestCount += 1
        }

        func recordStop() {
            lock.lock()
            defer { lock.unlock() }
            stopCount += 1
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(requestCount: requestCount, stopCount: stopCount)
        }
    }
}
