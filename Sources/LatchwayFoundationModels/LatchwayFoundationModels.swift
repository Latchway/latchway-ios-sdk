#if canImport(FoundationModels) && compiler(>=6.4)
@preconcurrency import Foundation
import FoundationModels
import Latchway

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public enum LatchwayFoundationModelsError: Error, Sendable, LocalizedError {
    case invalidTranscript
    case unsupportedSamplingMode
    case gateway(statusCode: Int, requestID: String?)
    case invalidGatewayStream

    public var errorDescription: String? {
        switch self {
        case .invalidTranscript:
            "The Foundation Models transcript has no translatable text input."
        case .unsupportedSamplingMode:
            "This Latchway adapter does not silently translate Foundation Models sampling modes."
        case let .gateway(statusCode, requestID):
            "Latchway returned HTTP \(statusCode)\(requestID.map { " (request \($0))" } ?? "")."
        case .invalidGatewayStream:
            "Latchway returned an invalid or incomplete Responses stream."
        }
    }
}

/// A Foundation Models custom provider backed by a feature-bound Latchway
/// Responses transport. Its capability declaration is intentionally empty:
/// v1 supports text transcripts and streaming, while guided generation,
/// attachments, reasoning, and tool calling fail explicitly until their wire
/// translations pass conformance.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public struct LatchwayLanguageModel: LanguageModel, Sendable {
    public struct Configuration: Hashable, Sendable {
        fileprivate let identity: UUID
        fileprivate let transport: LatchwayFeatureTransport

        public init(
            transport: LatchwayFeatureTransport
        ) {
            identity = UUID()
            self.transport = transport
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.identity == rhs.identity
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(identity)
        }
    }

    public typealias Executor = LatchwayLanguageModelExecutor

    public let capabilities = LanguageModelCapabilities([])
    public let executorConfiguration: Configuration

    public init(configuration: Configuration) {
        executorConfiguration = configuration
    }

    public init(
        client: LatchwayClient,
        feature: String,
        frameworkVersion: String
    ) {
        executorConfiguration = Configuration(
            transport: client.transport(
                feature: feature,
                framework: .foundationModels(version: frameworkVersion)
            )
        )
    }

    public init(
        client: LatchwayExtensionClient,
        feature: String,
        frameworkVersion: String
    ) {
        executorConfiguration = Configuration(
            transport: client.transport(
                feature: feature,
                framework: .foundationModels(version: frameworkVersion)
            )
        )
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public struct LatchwayLanguageModelExecutor: LanguageModelExecutor, Sendable {
    public typealias Configuration = LatchwayLanguageModel.Configuration
    public typealias Model = LatchwayLanguageModel

    private let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    public func prewarm(model _: Model, transcript _: Transcript) {
        // Remote Latchway routes have no local model assets to prewarm.
    }

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model _: Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        try Task.checkCancellation()
        if request.schema != nil {
            throw LanguageModelError.unsupportedGenerationGuide(.init(
                schemaName: nil,
                debugDescription: "Latchway v1 does not yet translate Foundation Models generation schemas."
            ))
        }
        if !request.enabledToolDefinitions.isEmpty {
            throw LanguageModelError.unsupportedCapability(.init(
                capability: .toolCalling,
                debugDescription: "Latchway v1 does not yet translate Foundation Models tool calls."
            ))
        }
        if request.generationOptions.samplingMode != nil {
            throw LatchwayFoundationModelsError.unsupportedSamplingMode
        }

        let body = try Self.makeRequestBody(from: request)
        var urlRequest = URLRequest(
            url: try configuration.transport.endpoint(path: "v1/responses")
        )
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try JSONEncoder().encode(body)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let stream = try await configuration.transport.bytes(for: urlRequest)
        guard (200 ... 299).contains(stream.response.statusCode) else {
            throw Self.gatewayError(from: stream.response)
        }

        var receivedTerminalEvent = false
        for try await line in stream.bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                receivedTerminalEvent = true
                break
            }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(ResponsesEvent.self, from: data)
            else { throw LatchwayFoundationModelsError.invalidGatewayStream }
            switch event.type {
            case "response.output_text.delta":
                guard let delta = event.delta else {
                    throw LatchwayFoundationModelsError.invalidGatewayStream
                }
                await channel.send(.response(action: .appendText(delta, tokenCount: 0)))
            case "response.completed":
                if let usage = event.response?.usage {
                    await channel.send(.response(action: .updateUsage(
                        input: .init(
                            totalTokenCount: usage.inputTokens,
                            cachedTokenCount: usage.inputTokensDetails?.cachedTokens ?? 0
                        ),
                        output: .init(
                            totalTokenCount: usage.outputTokens,
                            reasoningTokenCount: usage.outputTokensDetails?.reasoningTokens ?? 0
                        )
                    )))
                }
                receivedTerminalEvent = true
            case "response.failed", "error":
                throw LatchwayFoundationModelsError.gateway(
                    statusCode: stream.response.statusCode,
                    requestID: stream.response.value(forHTTPHeaderField: "X-Latchway-Request-ID")
                )
            default:
                continue
            }
        }
        guard receivedTerminalEvent else {
            throw LatchwayFoundationModelsError.invalidGatewayStream
        }
    }

    private struct ResponsesRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let instructions: String?
        let input: [Message]
        let stream = true
        let temperature: Double?
        let maxOutputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case instructions, input, stream, temperature
            case maxOutputTokens = "max_output_tokens"
        }
    }

    private struct ResponsesEvent: Decodable {
        struct Response: Decodable {
            struct Usage: Decodable {
                struct InputDetails: Decodable {
                    let cachedTokens: Int

                    enum CodingKeys: String, CodingKey {
                        case cachedTokens = "cached_tokens"
                    }
                }

                struct OutputDetails: Decodable {
                    let reasoningTokens: Int

                    enum CodingKeys: String, CodingKey {
                        case reasoningTokens = "reasoning_tokens"
                    }
                }

                let inputTokens: Int
                let outputTokens: Int
                let inputTokensDetails: InputDetails?
                let outputTokensDetails: OutputDetails?

                enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case outputTokens = "output_tokens"
                    case inputTokensDetails = "input_tokens_details"
                    case outputTokensDetails = "output_tokens_details"
                }
            }

            let usage: Usage?
        }

        let type: String
        let delta: String?
        let response: Response?
    }

    private static func makeRequestBody(
        from request: LanguageModelExecutorGenerationRequest
    ) throws -> ResponsesRequest {
        var instructions: [String] = []
        var messages: [ResponsesRequest.Message] = []
        var unsupported: [Transcript.Entry] = []

        for entry in request.transcript {
            switch entry {
            case let .instructions(value):
                if let text = text(from: value.segments) { instructions.append(text) }
                else { unsupported.append(entry) }
            case let .prompt(value):
                if let text = text(from: value.segments) {
                    messages.append(.init(role: "user", content: text))
                } else { unsupported.append(entry) }
            case let .response(value):
                if let text = text(from: value.segments) {
                    messages.append(.init(role: "assistant", content: text))
                } else { unsupported.append(entry) }
            case .toolCalls, .toolOutput, .reasoning:
                unsupported.append(entry)
            @unknown default:
                unsupported.append(entry)
            }
        }
        guard unsupported.isEmpty else {
            throw LanguageModelError.unsupportedTranscriptContent(.init(
                unsupportedContent: unsupported,
                debugDescription: "Latchway v1 accepts text-only instructions, prompts, and responses."
            ))
        }
        guard !messages.isEmpty else { throw LatchwayFoundationModelsError.invalidTranscript }
        return ResponsesRequest(
            instructions: instructions.isEmpty ? nil : instructions.joined(separator: "\n\n"),
            input: messages,
            temperature: request.generationOptions.temperature,
            maxOutputTokens: request.generationOptions.maximumResponseTokens
        )
    }

    private static func text(from segments: [Transcript.Segment]) -> String? {
        var values: [String] = []
        for segment in segments {
            guard case let .text(text) = segment else { return nil }
            values.append(text.content)
        }
        return values.joined()
    }

    private static func gatewayError(from response: HTTPURLResponse) -> Error {
        if response.statusCode == 429 {
            return LanguageModelError.rateLimited(.init(
                resetDate: nil,
                debugDescription: "Latchway quota or rate limit exceeded.",
                metadata: [
                    "request_id": response.value(forHTTPHeaderField: "X-Latchway-Request-ID") ?? "unknown",
                ]
            ))
        }
        return LatchwayFoundationModelsError.gateway(
            statusCode: response.statusCode,
            requestID: response.value(forHTTPHeaderField: "X-Latchway-Request-ID")
        )
    }
}
#endif
