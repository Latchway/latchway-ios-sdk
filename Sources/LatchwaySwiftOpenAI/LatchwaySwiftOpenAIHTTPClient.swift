@preconcurrency import Foundation
import Latchway
import SwiftOpenAI

/// A request-time SwiftOpenAI transport backed by Latchway's native DPoP
/// session and component key owners.
///
/// Unlike a static header adapter, every request is checked against the
/// configured gateway, receives a fresh DPoP proof immediately before
/// dispatch, and keeps the access and refresh credentials inside Latchway.
public struct LatchwaySwiftOpenAIHTTPClient: HTTPClient, Sendable {
    public static let testedFrameworkVersion = "4.6.0"

    public let transport: LatchwayFeatureTransport

    public init(
        client: LatchwayClient,
        feature: String,
        frameworkVersion: String = testedFrameworkVersion
    ) {
        transport = client.transport(
            feature: feature,
            framework: .swiftOpenAI(version: frameworkVersion)
        )
    }

    public init(
        client: LatchwayExtensionClient,
        feature: String,
        frameworkVersion: String = testedFrameworkVersion
    ) {
        transport = client.transport(
            feature: feature,
            framework: .swiftOpenAI(version: frameworkVersion)
        )
    }

    init(transport: LatchwayFeatureTransport) {
        self.transport = transport
    }

    /// The non-secret sentinel SwiftOpenAI may place in its Authorization
    /// header. Latchway removes exactly this value before native authorization.
    public var placeholderAPIKey: String { LatchwayFeatureTransport.placeholderAPIKey }

    /// Creates a SwiftOpenAI service whose ordinary and streaming HTTP paths
    /// both use this adapter. WebSocket Realtime is not supported because
    /// SwiftOpenAI currently dispatches that path through `URLSession.shared`.
    public func makeService(debugEnabled: Bool = false) throws -> any OpenAIService {
        let address = try Self.swiftOpenAIAddress(for: transport.gatewayBaseURL)
        return OpenAIServiceFactory.service(
            apiKey: placeholderAPIKey,
            overrideBaseURL: address.origin,
            proxyPath: address.proxyPath,
            overrideVersion: "v1",
            httpClient: self,
            debugEnabled: debugEnabled
        )
    }

    public func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
        let response = try await transport.send(Self.urlRequest(from: request))
        return (
            response.body,
            HTTPResponse(statusCode: response.statusCode, headers: response.headers)
        )
    }

    public func bytes(for request: HTTPRequest) async throws -> (HTTPByteStream, HTTPResponse) {
        let response = try await transport.bytes(for: Self.urlRequest(from: request))
        let lines = AsyncThrowingStream<String, Error>(bufferingPolicy: .bufferingOldest(1)) { continuation in
            let producer = Task {
                do {
                    for try await line in response.bytes.lines {
                        try Task.checkCancellation()
                        try await Self.yieldWithBackpressure(line, to: continuation)
                    }
                    response.finish()
                    continuation.finish()
                } catch is CancellationError {
                    response.cancel()
                    continuation.finish(throwing: LatchwayError.cancelled)
                } catch {
                    response.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
        var headers: [String: String] = [:]
        for (name, value) in response.response.allHeaderFields {
            guard let name = name as? String else { continue }
            headers[name] = String(describing: value)
        }
        return (
            .lines(lines),
            HTTPResponse(statusCode: response.response.statusCode, headers: headers)
        )
    }

    private static func urlRequest(from request: HTTPRequest) -> URLRequest {
        var result = URLRequest(url: request.url)
        result.httpMethod = request.method.rawValue
        result.httpBody = request.body
        for (name, value) in request.headers {
            result.setValue(value, forHTTPHeaderField: name)
        }
        return result
    }

    /// `AsyncThrowingStream` does not have an awaiting yield. A one-element,
    /// oldest-preserving buffer plus retrying the new element prevents both
    /// unbounded memory growth and event loss while the downstream decoder is
    /// slower than URLSession.
    private static func yieldWithBackpressure(
        _ value: String,
        to continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        while true {
            try Task.checkCancellation()
            switch continuation.yield(value) {
            case .enqueued:
                return
            case .dropped:
                await Task.yield()
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw CancellationError()
            }
        }
    }

    private static func swiftOpenAIAddress(for gateway: URL) throws -> (
        origin: String,
        proxyPath: String?
    ) {
        guard var components = URLComponents(url: gateway, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil
        else { throw LatchwayError.invalidConfiguration("The gateway URL is invalid") }
        let proxy = components.percentEncodedPath
            .split(separator: "/")
            .joined(separator: "/")
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.url?.absoluteString else {
            throw LatchwayError.invalidConfiguration("The gateway origin is invalid")
        }
        return (origin, proxy.isEmpty ? nil : proxy)
    }
}
