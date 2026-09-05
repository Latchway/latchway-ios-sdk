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

    // FW-REQ-103, FW-SEC-104
    @Test func fwREQ103AndSEC104FoundationModelsNeverExportsProviderPlaceholder() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        FoundationModelsURLProtocol.reset(stubs: [.response(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: responsesStream(deltas: ["credential safe"])
        )])
        let frameworkRecorder = FoundationModelsRequestRecorder()
        let accessToken = "foundation-models-native-access-token"
        let refreshToken = "foundation-models-native-refresh-token"
        let proof = "foundation-models-native-dpop-proof"
        let fixture = makeTransport(authorize: { request in
            await frameworkRecorder.record(request)
            var authorized = request
            authorized.setValue("DPoP \(accessToken)", forHTTPHeaderField: "Authorization")
            authorized.setValue(proof, forHTTPHeaderField: "DPoP")
            return authorized
        })
        let model = LatchwayLanguageModel(configuration: .init(transport: fixture.transport))

        let response = try await LanguageModelSession(model: model).respond(to: "Stay native")

        #expect(response.content == "credential safe")
        let frameworkRequest = try #require(await frameworkRecorder.requests.first)
        let frameworkVisible = [
            frameworkRequest.allHTTPHeaderFields?.description ?? "",
            frameworkRequest.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "",
        ].joined(separator: "\n")
        #expect(!frameworkVisible.contains(LatchwayFeatureTransport.placeholderAPIKey))
        #expect(!frameworkVisible.contains(accessToken))
        #expect(!frameworkVisible.contains(refreshToken))
        #expect(!frameworkVisible.contains(proof))
        #expect(frameworkRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(frameworkRequest.value(forHTTPHeaderField: "api-key") == nil)
        #expect(frameworkRequest.value(forHTTPHeaderField: "x-api-key") == nil)

        let dispatched = try #require(FoundationModelsURLProtocol.snapshot().requests.first)
        #expect(dispatched.value(forHTTPHeaderField: "Authorization") == "DPoP \(accessToken)")
        #expect(dispatched.value(forHTTPHeaderField: "DPoP") == proof)
        let dispatchedHeaders = dispatched.allHTTPHeaderFields?.description ?? ""
        #expect(!dispatchedHeaders.contains(LatchwayFeatureTransport.placeholderAPIKey))
        #expect(!dispatchedHeaders.contains(refreshToken))
    }

    // FW-REQ-104 and FW-SEC-102 public-path half: Apple's session API reaches
    // this custom model with no caller header or Authorization surface. The
    // shared native transport tests cover allowed-header preservation and
    // duplicate rejection before dispatch.
    @Test func fwREQ104AndSEC102FoundationModelsExposeNoCallerHeaderSurface() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        FoundationModelsURLProtocol.reset(stubs: [.response(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: responsesStream(deltas: ["header safe"])
        )])
        let fixture = makeTransport()
        let configuration = LatchwayLanguageModel.Configuration(transport: fixture.transport)
        let model = LatchwayLanguageModel(configuration: configuration)

        _ = try await LanguageModelSession(model: model).respond(to: "No header API")

        let request = try #require(await fixture.recorder.requests.first)
        let names = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        #expect(names == ["accept", "content-type"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        let configurationFields = Set(
            Mirror(reflecting: configuration).children.compactMap(\.label)
        )
        #expect(configurationFields == ["identity", "transport"])
    }

    // FW-BEH-107 adapter half: there is no logger or debug hook; the shared
    // native transport test separately locks the no-logging boundary.
    @Test func fwBEH107FoundationModelsExposesNoLoggerSurface() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/LatchwayFoundationModels/LatchwayFoundationModels.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for loggingCall in ["print(", "debugPrint(", "dump(", "Logger(", "Logger.", "os_log(", "NSLog("] {
            #expect(!source.contains(loggingCall))
        }
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

    @Test func guidedGenerationUsesTheActualFrameworkDecoder() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        FoundationModelsURLProtocol.reset(stubs: [.response(
            statusCode: 200, headers: ["Content-Type": "text/event-stream"],
            body: responsesStream(deltas: ["{\"value\":", "\"guided\"}"])
        )])
        let fixture = makeTransport()
        let model = LatchwayLanguageModel(configuration: .init(transport: fixture.transport))
        #expect(model.capabilities.contains(.guidedGeneration))
        #expect(model.capabilities.contains(.toolCalling))

        let structured = LanguageModelSession(model: model)
        let response = try await structured.respond(to: "Return a value", generating: StructuredAnswer.self)
        #expect(response.content.value == "guided")
        let request = try #require(await fixture.recorder.requests.first)
        let body = try requestJSONObject(request)
        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["strict"] as? Bool == true)
        #expect(schema["type"] as? String == "object")
        #expect((schema["properties"] as? [String: Any])?["value"] != nil)
        #expect(body["model"] as? String == "latchway-feature")
        #expect(body["store"] as? Bool == false)
    }

    @Test func toolLoopAndLaterTurnPreserveCallIDsAndResults() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        FoundationModelsURLProtocol.reset(stubs: [
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: toolStream()),
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: responsesStream(deltas: ["Tool returned sunny"])),
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: responsesStream(deltas: ["You asked about sunny weather"])),
        ])
        let fixture = makeTransport()
        let model = LatchwayLanguageModel(configuration: .init(transport: fixture.transport))
        let session = LanguageModelSession(model: model, tools: [EchoTool()])
        let first = try await session.respond(to: "Call echo with sunny")
        #expect(first.content == "Tool returned sunny")
        let second = try await session.respond(to: "What did I ask?")
        #expect(second.content == "You asked about sunny weather")
        let requests = await fixture.recorder.requests
        #expect(requests.count == 3)
        let body = try requestJSONObject(requests[1])
        let input = try #require(body["input"] as? [[String: Any]])
        let call = try #require(input.first { $0["type"] as? String == "function_call" })
        let result = try #require(input.first { $0["type"] as? String == "function_call_output" })
        #expect(call["call_id"] as? String == "call_weather_1")
        #expect(result["call_id"] as? String == "call_weather_1")
        #expect(result["output"] as? String == "sunny")
        let finalInput = try #require(try requestJSONObject(requests[2])["input"] as? [[String: Any]])
        #expect(finalInput.contains { $0["type"] as? String == "function_call_output" })
        #expect(session.usage.input.totalTokenCount == 6)
    }

    @Test func generationFieldsAreTranslatedWithoutChangingIdentityHeaders() throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let id = UUID()
        var request = LanguageModelExecutorGenerationRequest(
            id: id, transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "hello"))]))]),
            enabledTools: [Transcript.ToolDefinition(tool: EchoTool())], schema: StructuredAnswer.generationSchema,
            generationOptions: .init(samplingMode: .random(probabilityThreshold: 0.8), temperature: 0.6, maximumResponseTokens: 123, toolCallingMode: .required),
            contextOptions: .init(includeSchemaInPrompt: true, reasoningLevel: .moderate),
            metadata: ["sample": GeneratedContent(kind: .structure(properties: ["count": GeneratedContent(2)], orderedKeys: ["count"]))]
        )
        let body = try #require(JSONSerialization.jsonObject(with: FoundationModelsRequest.encode(request)) as? [String: Any])
        #expect(body["top_p"] as? Double == 0.8)
        #expect(body["temperature"] as? Double == 0.6)
        #expect(body["max_output_tokens"] as? Int == 123)
        #expect(body["tool_choice"] as? String == "required")
        #expect((body["reasoning"] as? [String: String])?["effort"] == "medium")
        #expect((body["metadata"] as? [String: String])?["latchway_generation_id"] == id.uuidString)
        #expect((body["instructions"] as? String)?.contains("schema") == true)
        request.generationOptions.samplingMode = .greedy
        let greedy = try #require(JSONSerialization.jsonObject(with: FoundationModelsRequest.encode(request)) as? [String: Any])
        #expect(greedy["temperature"] as? Int == 0)
        request.generationOptions.samplingMode = .random(top: 20)
        let topK = try #require(JSONSerialization.jsonObject(with: FoundationModelsRequest.encode(request)) as? [String: Any])
        #expect(topK["top_k"] as? Int == 20)
        request.generationOptions.samplingMode = .random(top: 20, seed: 42)
        #expect(throws: LatchwayFoundationModelsError.self) { try FoundationModelsRequest.encode(request) }
    }

    @Test func incompleteAndDisabledToolStreamsNeverRunTools() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        for body in [Data("data: [DONE]\n\n".utf8), toolStream(name: "not_enabled"), toolStream(completed: false)] {
            FoundationModelsURLProtocol.reset(stubs: [.response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: body)])
            let fixture = makeTransport()
            let session = LanguageModelSession(model: LatchwayLanguageModel(configuration: .init(transport: fixture.transport)), tools: [EchoTool()])
            await #expect(throws: (any Error).self) { try await session.respond(to: "test") }
            #expect(await fixture.recorder.requests.count == 1)
        }
    }

    @Test func parallelCallsAndCRDelimitedEventsPreserveDistinctResults() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let items: [[String: Any]] = ["one", "two"].map { value in
            ["type": "function_call", "id": "fc_" + value, "call_id": "call_" + value,
             "name": "echo", "arguments": "{\"value\":\"\(value)\"}"]
        }
        let completed: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": items]]
        let data = Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: completed), as: UTF8.self) + "\r\r").utf8)
        FoundationModelsURLProtocol.reset(stubs: [
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: data),
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: responsesStream(deltas: ["both returned"])),
        ])
        let fixture = makeTransport()
        let session = LanguageModelSession(model: LatchwayLanguageModel(configuration: .init(transport: fixture.transport)), tools: [EchoTool()])
        #expect(try await session.respond(to: "Call echo twice").content == "both returned")
        let requests = await fixture.recorder.requests
        #expect(requests.count == 2)
        let input = try #require(try requestJSONObject(requests[1])["input"] as? [[String: Any]])
        let outputs = input.filter { $0["type"] as? String == "function_call_output" }
        #expect(Set(outputs.compactMap { $0["call_id"] as? String }) == ["call_one", "call_two"])
        #expect(Set(outputs.compactMap { $0["output"] as? String }) == ["one", "two"])
    }

    @Test func reasoningAndNullableNestedSchemaRoundTrip() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Nested", properties: [
            .init(name: "city", schema: .init(type: String.self)),
            .init(name: "note", schema: .init(type: String.self), isOptional: true),
        ]), dependencies: [])
        let normalized = try FoundationModelsRequest.schemaObject(schema)
        #expect(Set(normalized["required"] as? [String] ?? []) == ["city", "note"])
        let properties = try #require(normalized["properties"] as? [String: [String: Any]])
        #expect(properties["note"]?["anyOf"] != nil)
        let completed: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": [
            ["type": "reasoning", "id": "rs_test", "summary": [["type": "summary_text", "text": "Check the result."]], "encrypted_content": "opaque-signature"],
            ["type": "message", "id": "msg_test", "content": [["type": "output_text", "text": "Ready."]]],
        ]]]
        let data = Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: completed), as: UTF8.self) + "\n\n").utf8)
        FoundationModelsURLProtocol.reset(stubs: [
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: data),
            .response(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: responsesStream(deltas: ["Next."])),
        ])
        let fixture = makeTransport()
        let session = LanguageModelSession(model: LatchwayLanguageModel(configuration: .init(transport: fixture.transport)))
        #expect(try await session.respond(to: "Reason briefly").content == "Ready.")
        _ = try await session.respond(to: "Continue")
        let requests = await fixture.recorder.requests
        let input = try #require(try requestJSONObject(requests[1])["input"] as? [[String: Any]])
        let reasoning = try #require(input.first { $0["type"] as? String == "reasoning" })
        #expect(reasoning["id"] as? String == "rs_test")
        #expect(reasoning["encrypted_content"] as? String == "opaque-signature")
    }

    // FW-BEH-105, FW-BEH-106
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
            guard case let .rateLimited(context) = error else {
                Issue.record("Unexpected quota error: \(error)")
                return
            }
            #expect(
                context.metadata["request_id"] as? String
                    == "request-quota-12345678"
            )
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

private func toolStream(name: String = "echo", completed: Bool = true) -> Data {
    let item: [String: Any] = ["type": "function_call", "id": "fc_weather_1", "call_id": "call_weather_1", "name": name, "arguments": ""]
    var events: [[String: Any]] = [
        ["type": "response.output_item.added", "item": item],
        ["type": "response.function_call_arguments.delta", "item_id": "fc_weather_1", "delta": "{\"value\":"],
        ["type": "response.function_call_arguments.delta", "item_id": "fc_weather_1", "delta": "\"sunny\"}"],
    ]
    if completed { events.append(["type": "response.completed", "response": ["status": "completed", "usage": ["input_tokens": 2, "output_tokens": 2]]]) }
    return Data(events.map { event in
        "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n"
    }.joined().utf8)
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
