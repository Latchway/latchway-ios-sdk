@preconcurrency import Foundation

public struct LatchwayFrameworkMetadata: Sendable, Hashable {
    public let identifier: String
    public let version: String

    public init(identifier: String, version: String) {
        self.identifier = identifier
        self.version = version
    }

    public static func foundationModels(version: String) -> Self {
        .init(identifier: "foundation-models", version: version)
    }

    public static func swiftOpenAI(version: String) -> Self {
        .init(identifier: "swift-openai", version: version)
    }

    func validate() throws {
        let supported: Set<String> = [
            "foundation-models", "macpaw-openai", "swift-openai",
        ]
        guard supported.contains(identifier) else {
            throw LatchwayError.invalidRequest("The framework integration is not registered")
        }
        guard version.range(
            of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$",
            options: .regularExpression
        ) != nil,
        version.utf8.count <= 128
        else {
            throw LatchwayError.invalidRequest("The framework version must use contract semver syntax")
        }
    }
}

/// The response head and incrementally consumed bytes for a native request.
///
/// `URLSession.AsyncBytes` preserves task cancellation and applies consumer
/// backpressure. Latchway does not buffer the stream or replay it after any
/// response bytes have become visible.
public struct LatchwayStreamingResponse: Sendable {
    public let response: HTTPURLResponse
    public let bytes: URLSession.AsyncBytes

    init(response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        self.response = response
        self.bytes = bytes
    }
}

/// A feature-bound, framework-aware authenticated HTTP transport.
///
/// Framework adapters use this value underneath their existing request and
/// response types. The only provider placeholder accepted is the literal
/// `latchway-managed`; every other credential-like header or query field is
/// rejected before a DPoP credential is attached.
public struct LatchwayFeatureTransport: Sendable {
    public static let placeholderAPIKey = "latchway-managed"

    private let feature: String
    private let framework: LatchwayFrameworkMetadata?
    private let baseURL: URL
    private let session: URLSession
    private let authorizeOperation: @Sendable (URLRequest) async throws -> URLRequest
    private let sendOperation: @Sendable (URLRequest) async throws -> LatchwayHTTPResponse

    init(
        feature: String,
        framework: LatchwayFrameworkMetadata?,
        baseURL: URL,
        session: URLSession? = nil,
        authorize: @escaping @Sendable (URLRequest) async throws -> URLRequest,
        send: @escaping @Sendable (URLRequest) async throws -> LatchwayHTTPResponse
    ) {
        self.feature = feature
        self.framework = framework
        self.baseURL = baseURL
        self.session = session ?? LatchwayURLSessionFactory.make()
        authorizeOperation = authorize
        sendOperation = send
    }

    public func authorize(_ request: URLRequest) async throws -> URLRequest {
        try await authorizeOperation(request)
    }

    public func send(_ request: URLRequest) async throws -> LatchwayHTTPResponse {
        try await sendOperation(request)
    }

    public func bytes(for request: URLRequest) async throws -> LatchwayStreamingResponse {
        let authorized = try await authorizeOperation(request)
        do {
            let (bytes, response) = try await session.bytes(for: authorized)
            guard let http = response as? HTTPURLResponse else {
                throw LatchwayError.invalidServerResponse
            }
            guard !(300 ... 399).contains(http.statusCode) else {
                throw LatchwayError.invalidServerResponse
            }
            try Task.checkCancellation()
            return LatchwayStreamingResponse(response: http, bytes: bytes)
        } catch is CancellationError {
            throw LatchwayError.cancelled
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw LatchwayError.cancelled
        } catch let error as LatchwayError {
            throw error
        } catch {
            throw LatchwayError.transportFailure
        }
    }

    public var boundFeature: String { feature }
    public var frameworkMetadata: LatchwayFrameworkMetadata? { framework }
    /// Public gateway address only; never contains a token or key material.
    public var gatewayBaseURL: URL { baseURL }

    public func endpoint(path: String) throws -> URL {
        guard path.range(
            of: "^v1(?:/[A-Za-z0-9._~!$&'()*+,;=:@%-]+)*$",
            options: .regularExpression
        ) != nil else {
            throw LatchwayError.invalidRequest("The data-plane path is invalid")
        }
        return baseURL.appendingPathComponent(path)
    }
}
