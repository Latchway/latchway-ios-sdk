#if canImport(FoundationModels) && compiler(>=6.4) && !os(tvOS)
import Foundation
import FoundationModels
import Testing
@testable import Latchway
@testable import LatchwayFoundationModels

@Suite(.serialized)
struct FoundationModelsPublicAPITests {
    @Test func errorDescriptionsAreSafe() {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        #expect(LatchwayFoundationModelsError.invalidGatewayStream.errorDescription != nil)
        #expect(LatchwayFoundationModelsError.invalidTranscript.errorDescription != nil)
        #expect(LatchwayFoundationModelsError.invalidTranscript.code == "foundation_models_invalid_transcript")
        #expect(
            LatchwayFoundationModelsError.invalidTranscript.documentationURL.absoluteString
                == "https://docs.latchway.dev/errors/foundation-models-invalid-transcript"
        )
    }

    @Test func singleTurnGenerationUsesResponsesStreamingTransport() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        FoundationModelsURLProtocol.reset(stubs: [.response(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: responsesStream(deltas: ["Hello", " from Latchway"])
        )])
        let fixture = makeTransport()
        #expect(fixture.transport.frameworkMetadata == .foundationModels(version: "27.0.0"))
        let model = LatchwayLanguageModel(configuration: .init(transport: fixture.transport))
        let session = LanguageModelSession(model: model)

        let response = try await session.respond(to: "Say hello")

        #expect(response.content == "Hello from Latchway")
        let request = try #require(await fixture.recorder.requests.first)
        #expect(request.url?.path == "/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        let body = try requestJSONObject(request)
        #expect(body["stream"] as? Bool == true)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { $0["role"] as? String } == ["user"])
        #expect(input.map { $0["content"] as? String } == ["Say hello"])
    }

    @Test func multiTurnTranscriptPreservesUserAndAssistantHistory() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        FoundationModelsURLProtocol.reset(stubs: [
            .response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: responsesStream(deltas: ["First answer"])
            ),
            .response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: responsesStream(deltas: ["Second answer"])
            ),
        ])
        let fixture = makeTransport()
        let model = LatchwayLanguageModel(configuration: .init(transport: fixture.transport))
        let session = LanguageModelSession(model: model, instructions: "Be concise")

        _ = try await session.respond(to: "First question")
        let second = try await session.respond(to: "Second question")

        #expect(second.content == "Second answer")
        let requests = await fixture.recorder.requests
        #expect(requests.count == 2)
        let body = try requestJSONObject(requests[1])
        #expect(body["instructions"] as? String == "Be concise")
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(input.map { $0["content"] as? String } == [
            "First question", "First answer", "Second question",
        ])
    }

    @Test func streamingProducesIncrementalTextAndUsage() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        FoundationModelsURLProtocol.reset(stubs: [.response(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: responsesStream(
                deltas: ["one", " two", " three"],
                inputTokens: 4,
                outputTokens: 3
            )
        )])
        let fixture = makeTransport()
        let model = LatchwayLanguageModel(configuration: .init(transport: fixture.transport))
        let session = LanguageModelSession(model: model)

        var snapshots: [String] = []
        for try await snapshot in session.streamResponse(to: "Count") {
            snapshots.append(snapshot.content)
        }

        #expect(snapshots.count >= 2)
        #expect(snapshots.last == "one two three")
        #expect(session.usage.input.totalTokenCount == 4)
        #expect(session.usage.output.totalTokenCount == 3)
    }

    @Test func guidedGenerationAndToolsFailExplicitlyWithoutDispatch() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        FoundationModelsURLProtocol.reset(stubs: [])
        let fixture = makeTransport()
        let model = LatchwayLanguageModel(configuration: .init(transport: fixture.transport))
        #expect(!model.capabilities.contains(.guidedGeneration))
        #expect(!model.capabilities.contains(.toolCalling))

        let structured = LanguageModelSession(model: model)
        do {
            let _: LanguageModelSession.Response<StructuredAnswer> = try await structured.respond(
                to: "Return a value",
                generating: StructuredAnswer.self
            )
            Issue.record("Guided generation must fail until its translation is implemented")
        } catch let error as LanguageModelError {
            switch error {
            case .unsupportedGenerationGuide, .unsupportedCapability:
                break
            default:
                Issue.record("Unexpected guided-generation error: \(error)")
            }
        }

        let withTool = LanguageModelSession(model: model, tools: [EchoTool()])
        do {
            _ = try await withTool.respond(to: "Call the echo tool")
            Issue.record("Tool calling must fail until its translation is implemented")
        } catch let error as LanguageModelError {
            guard case .unsupportedCapability = error else {
                Issue.record("Unexpected tool-capability error: \(error)")
                return
            }
        }
        #expect(FoundationModelsURLProtocol.snapshot().requests.isEmpty)
    }

    @Test func quotaAndUnavailableFeatureFailuresMapTruthfully() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        FoundationModelsURLProtocol.reset(stubs: [
            .response(
                statusCode: 429,
                headers: [
                    "Content-Type": "application/problem+json",
                    "X-Latchway-Request-ID": "request-quota-12345678",
                ],
                body: Data()
            ),
            .response(
                statusCode: 404,
                headers: ["X-Latchway-Request-ID": "request-feature-12345678"],
                body: Data()
            ),
        ])
        let fixture = makeTransport()
        let model = LatchwayLanguageModel(configuration: .init(transport: fixture.transport))

        do {
            _ = try await LanguageModelSession(model: model).respond(to: "quota")
            Issue.record("HTTP 429 must map to Foundation Models rateLimited")
        } catch let error as LanguageModelError {
            guard case .rateLimited = error else {
                Issue.record("Unexpected quota error: \(error)")
                return
            }
        }

        do {
            _ = try await LanguageModelSession(model: model).respond(to: "missing feature")
            Issue.record("Unavailable features must remain explicit")
        } catch let error as LatchwayFoundationModelsError {
            guard case let .gateway(statusCode, requestID) = error else {
                Issue.record("Unexpected unavailable-feature error: \(error)")
                return
            }
            #expect(statusCode == 404)
            #expect(requestID == "request-feature-12345678")
        }
    }

    @Test func cancellationStopsTheNativeStream() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        FoundationModelsURLProtocol.reset(stubs: [.hanging])
        let fixture = makeTransport()
        let model = LatchwayLanguageModel(configuration: .init(transport: fixture.transport))
        let task = Task {
            try await LanguageModelSession(model: model).respond(to: "wait forever")
        }
        try await waitUntil { !FoundationModelsURLProtocol.snapshot().requests.isEmpty }

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled Foundation Models request must not complete")
        } catch is CancellationError {
            // Native Foundation Models may preserve CancellationError directly.
        } catch let error as LatchwayError {
            #expect(error == .cancelled)
        }
        try await waitUntil { FoundationModelsURLProtocol.snapshot().stopCount > 0 }
    }

    @Test func adapterPreservesTransportAttestationRefreshRetry() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        FoundationModelsURLProtocol.reset(stubs: [
            .response(
                statusCode: 401,
                headers: [
                    "Content-Type": "application/problem+json",
                    "X-Latchway-Request-ID": "request-refresh-12345678",
                ],
                body: try sessionExpiredProblem(requestID: "request-refresh-12345678")
            ),
            .response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: responsesStream(deltas: ["refreshed"])
            ),
        ])
        let retry = RetryCounter()
        let fixture = makeTransport(
            authorize: { request in
                var request = request
                request.setValue("request-refresh-12345678", forHTTPHeaderField: "X-Latchway-Request-ID")
                request.setValue("DPoP session-one", forHTTPHeaderField: "Authorization")
                return request
            },
            streamingRetry: { request, _, _ in
                await retry.increment()
                var request = request
                request.setValue("request-refresh-12345678", forHTTPHeaderField: "X-Latchway-Request-ID")
                request.setValue("DPoP session-two", forHTTPHeaderField: "Authorization")
                return request
            }
        )
        let model = LatchwayLanguageModel(configuration: .init(transport: fixture.transport))

        let response = try await LanguageModelSession(model: model).respond(to: "refresh")

        #expect(response.content == "refreshed")
        #expect(await retry.value == 1)
        let requests = FoundationModelsURLProtocol.snapshot().requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "DPoP session-one")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "DPoP session-two")
    }

    @Test func appExtensionInitializerRemainsAFirstClassPublicBoundary() {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let constructor: @Sendable (
            LatchwayExtensionClient,
            String,
            String
        ) -> LatchwayLanguageModel = { client, feature, version in
            LatchwayLanguageModel(
                client: client,
                feature: feature,
                frameworkVersion: version
            )
        }
        _ = constructor
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
@Generable
private struct StructuredAnswer {
    let value: String
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
@Generable
private struct EchoArguments {
    let value: String
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
private struct EchoTool: Tool {
    let name = "echo"
    let description = "Returns the supplied value."

    func call(arguments: EchoArguments) async throws -> String {
        arguments.value
    }
}

private struct FoundationModelsTransportFixture {
    let transport: LatchwayFeatureTransport
    let recorder: FoundationModelsRequestRecorder
}

private func makeTransport(
    authorize: @escaping @Sendable (URLRequest) async throws -> URLRequest = { $0 },
    streamingRetry: (@Sendable (
        URLRequest,
        URLRequest,
        SafeRetryDirective
    ) async throws -> URLRequest)? = nil
) -> FoundationModelsTransportFixture {
    let recorder = FoundationModelsRequestRecorder()
    let transport = LatchwayFeatureTransport(
        feature: "foundation-models-test",
        framework: .foundationModels(version: "27.0.0"),
        baseURL: URL(string: "https://gateway.example.test")!,
        makeSession: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FoundationModelsURLProtocol.self]
            return URLSession(configuration: configuration)
        },
        authorize: { request in
            let authorized = try await authorize(request)
            await recorder.record(authorized)
            return authorized
        },
        send: { _ in throw LatchwayError.transportFailure },
        streamingRetry: streamingRetry
    )
    return .init(transport: transport, recorder: recorder)
}

private func responsesStream(
    deltas: [String],
    inputTokens: Int = 2,
    outputTokens: Int = 2
) -> Data {
    var lines = deltas.map { delta in
        let encoded = try! JSONSerialization.data(withJSONObject: [
            "type": "response.output_text.delta",
            "delta": delta,
        ], options: [.sortedKeys])
        return "data: \(String(decoding: encoded, as: UTF8.self))\n\n"
    }
    let completed = try! JSONSerialization.data(withJSONObject: [
        "type": "response.completed",
        "response": [
            "usage": [
                "input_tokens": inputTokens,
                "output_tokens": outputTokens,
                "input_tokens_details": ["cached_tokens": 0],
                "output_tokens_details": ["reasoning_tokens": 0],
            ],
        ],
    ], options: [.sortedKeys])
    lines.append("data: \(String(decoding: completed, as: UTF8.self))\n\n")
    return Data(lines.joined().utf8)
}

private func sessionExpiredProblem(requestID: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "type": "https://docs.latchway.dev/errors/session-expired",
        "documentation_url": "https://docs.latchway.dev/errors/session-expired",
        "title": "Session expired",
        "status": 401,
        "detail": "The Latchway session is expired.",
        "code": "session_expired",
        "request_id": requestID,
        "retryable": true,
    ], options: [.sortedKeys])
}

private func requestJSONObject(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private actor RetryCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor FoundationModelsRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw FoundationModelsTestError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum FoundationModelsTestError: Error {
    case timedOut
}

private final class FoundationModelsURLProtocol: URLProtocol, @unchecked Sendable {
    enum Stub: Sendable {
        case response(statusCode: Int, headers: [String: String], body: Data)
        case hanging
    }

    struct Snapshot: Sendable {
        let requests: [URLRequest]
        let stopCount: Int
    }

    private static let state = State()

    static func reset(stubs: [Stub]) {
        state.reset(stubs: stubs)
    }

    static func snapshot() -> Snapshot {
        state.snapshot()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "gateway.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.state.next(request: request)
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch stub {
        case let .response(statusCode, headers, body):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .hanging:
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            ) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }

    override func stopLoading() {
        Self.state.recordStop()
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stubs: [Stub] = []
        private var requests: [URLRequest] = []
        private var stopCount = 0

        func reset(stubs: [Stub]) {
            lock.lock()
            defer { lock.unlock() }
            self.stubs = stubs
            requests = []
            stopCount = 0
        }

        func next(request: URLRequest) -> Stub {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            guard !stubs.isEmpty else {
                return .response(statusCode: 500, headers: [:], body: Data())
            }
            return stubs.removeFirst()
        }

        func recordStop() {
            lock.lock()
            stopCount += 1
            lock.unlock()
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(requests: requests, stopCount: stopCount)
        }
    }
}
#endif
