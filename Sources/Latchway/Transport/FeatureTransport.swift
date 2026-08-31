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

/// A single-pass, backpressure-aware asynchronous response body.
///
/// Successful responses and bodies that cannot be safe-retry problems are
/// backed directly by `URLSession.AsyncBytes`. When Latchway must inspect a
/// bounded 401 problem body, this sequence replays the inspected bytes if the
/// response does not contain a valid safe-retry directive. Callers therefore
/// observe the original response body regardless of retry classification.
public struct LatchwayAsyncBytes: AsyncSequence, Sendable {
    public typealias Element = UInt8

    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        private let prefix: Data
        private var prefixIndex: Int
        private var lookahead: UInt8?
        private var remainder: URLSession.AsyncBytes.Iterator?

        fileprivate init(
            prefix: Data,
            lookahead: UInt8?,
            remainder: URLSession.AsyncBytes.Iterator?
        ) {
            self.prefix = prefix
            prefixIndex = 0
            self.lookahead = lookahead
            self.remainder = remainder
        }

        public mutating func next() async throws -> UInt8? {
            if prefixIndex < prefix.count {
                defer { prefixIndex += 1 }
                return prefix[prefixIndex]
            }
            if let lookahead {
                self.lookahead = nil
                return lookahead
            }
            guard var remainder else { return nil }
            let byte = try await remainder.next()
            self.remainder = remainder
            return byte
        }
    }

    private enum Storage: Sendable {
        case native(URLSession.AsyncBytes)
        case buffered(Data)
        case resumed(Data, UInt8, URLSession.AsyncBytes.Iterator)
    }

    private let storage: Storage

    fileprivate init(_ bytes: URLSession.AsyncBytes) {
        storage = .native(bytes)
    }

    fileprivate init(buffered bytes: Data) {
        storage = .buffered(bytes)
    }

    fileprivate init(
        prefix: Data,
        lookahead: UInt8,
        remainder: URLSession.AsyncBytes.Iterator
    ) {
        storage = .resumed(prefix, lookahead, remainder)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        switch storage {
        case let .native(bytes):
            AsyncIterator(
                prefix: Data(),
                lookahead: nil,
                remainder: bytes.makeAsyncIterator()
            )
        case let .buffered(bytes):
            AsyncIterator(prefix: bytes, lookahead: nil, remainder: nil)
        case let .resumed(prefix, lookahead, remainder):
            AsyncIterator(
                prefix: prefix,
                lookahead: lookahead,
                remainder: remainder
            )
        }
    }
}

/// The response head and incrementally consumed bytes for a native request.
///
/// Successful response bodies are never buffered. Before any response bytes
/// become visible, Latchway may inspect one bounded 401 problem body and replay
/// only a contract-proven pre-dispatch rejection.
public struct LatchwayStreamingResponse: Sendable {
    public let response: HTTPURLResponse
    public let bytes: LatchwayAsyncBytes

    private let finishOperation: @Sendable () -> Void
    private let cancelOperation: @Sendable () -> Void

    init(response: HTTPURLResponse, bytes: URLSession.AsyncBytes, session: URLSession) {
        self.init(
            response: response,
            bytes: LatchwayAsyncBytes(bytes),
            session: session
        )
    }

    init(response: HTTPURLResponse, bytes: LatchwayAsyncBytes, session: URLSession) {
        self.response = response
        self.bytes = bytes
        finishOperation = { session.finishTasksAndInvalidate() }
        cancelOperation = { session.invalidateAndCancel() }
    }

    /// Releases the request's private URL session after all response bytes
    /// have been consumed.
    public func finish() {
        finishOperation()
    }

    /// Cancels the streaming request and releases its private URL session.
    ///
    /// Call this when the consumer stops before reaching the end of `bytes`.
    public func cancel() {
        cancelOperation()
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
    private let sessionFactory: @Sendable () -> URLSession
    private let authorizeOperation: @Sendable (URLRequest) async throws -> URLRequest
    private let sendOperation: @Sendable (URLRequest) async throws -> LatchwayHTTPResponse
    private let streamingRetryOperation: (@Sendable (
        URLRequest,
        URLRequest,
        SafeRetryDirective
    ) async throws -> URLRequest)?

    init(
        feature: String,
        framework: LatchwayFrameworkMetadata?,
        baseURL: URL,
        session: URLSession? = nil,
        makeSession: (@Sendable () -> URLSession)? = nil,
        authorize: @escaping @Sendable (URLRequest) async throws -> URLRequest,
        send: @escaping @Sendable (URLRequest) async throws -> LatchwayHTTPResponse,
        streamingRetry: (@Sendable (
            URLRequest,
            URLRequest,
            SafeRetryDirective
        ) async throws -> URLRequest)? = nil
    ) {
        self.feature = feature
        self.framework = framework
        self.baseURL = baseURL
        if let makeSession {
            sessionFactory = makeSession
        } else if let session {
            sessionFactory = { session }
        } else {
            sessionFactory = { LatchwayURLSessionFactory.make() }
        }
        authorizeOperation = authorize
        sendOperation = send
        streamingRetryOperation = streamingRetry
    }

    public func authorize(_ request: URLRequest) async throws -> URLRequest {
        try await authorizeOperation(request)
    }

    public func send(_ request: URLRequest) async throws -> LatchwayHTTPResponse {
        try await sendOperation(request)
    }

    /// Authorizes and dispatches a native streaming request.
    ///
    /// A first `session_expired` or `dpop_nonce_required` response is buffered
    /// up to the protocol's 64 KiB problem limit, validated by the same strict
    /// safe-retry parser as ``send(_:)``, and replayed once. Successful streams,
    /// non-candidate responses, second responses, and `httpBodyStream` requests
    /// are returned without response-body buffering or automatic replay. A
    /// candidate that is malformed, non-retryable, or larger than the problem
    /// limit is returned with its complete original response body available.
    public func bytes(for request: URLRequest) async throws -> LatchwayStreamingResponse {
        do {
            let authorized = try await authorizeOperation(request)
            let session = sessionFactory()
            do {
                return try await bytes(
                    for: request,
                    authorized: authorized,
                    session: session
                )
            } catch {
                session.invalidateAndCancel()
                throw error
            }
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

    private func bytes(
        for request: URLRequest,
        authorized: URLRequest,
        session: URLSession
    ) async throws -> LatchwayStreamingResponse {
        let first = try await dispatch(authorized, session: session)
        guard request.httpBodyStream == nil,
              let streamingRetryOperation,
              SafeRetryDirective.hasCandidateResponseHead(
                  response: Self.httpResponse(first.response, body: Data()),
                  expectedRequestID: authorized.value(
                      forHTTPHeaderField: "X-Latchway-Request-ID"
                  )
              )
        else {
            return LatchwayStreamingResponse(
                response: first.response,
                bytes: first.bytes,
                session: session
            )
        }

        let expectedLength = first.response.expectedContentLength
        guard expectedLength <= 0
            || expectedLength <= Int64(SafeRetryDirective.maximumProblemBytes)
        else {
            // The response is provably too large to be a safe-retry problem.
            // Its bytes are still untouched, so preserve the ordinary
            // streaming response behavior instead of consuming it.
            return LatchwayStreamingResponse(
                response: first.response,
                bytes: first.bytes,
                session: session
            )
        }

        let problemBody = try await Self.readBoundedProblemBody(
            response: first.response,
            bytes: first.bytes
        )
        let body: Data
        switch problemBody {
        case let .complete(buffered):
            body = buffered
        case let .exceedsLimit(prefix, lookahead, remainder):
            return LatchwayStreamingResponse(
                response: first.response,
                bytes: LatchwayAsyncBytes(
                    prefix: prefix,
                    lookahead: lookahead,
                    remainder: remainder
                ),
                session: session
            )
        }

        let problemResponse = Self.httpResponse(first.response, body: body)
        guard let directive = SafeRetryDirective.parse(
            response: problemResponse,
            expectedRequestID: authorized.value(
                forHTTPHeaderField: "X-Latchway-Request-ID"
            )
        ) else {
            return LatchwayStreamingResponse(
                response: first.response,
                bytes: LatchwayAsyncBytes(buffered: body),
                session: session
            )
        }
        let retry = try await streamingRetryOperation(
            request,
            authorized,
            directive
        )
        try Task.checkCancellation()
        let second = try await dispatch(retry, session: session)
        return LatchwayStreamingResponse(
            response: second.response,
            bytes: second.bytes,
            session: session
        )
    }

    private func dispatch(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (bytes: URLSession.AsyncBytes, response: HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              !(300 ... 399).contains(http.statusCode)
        else { throw LatchwayError.invalidServerResponse }
        try Task.checkCancellation()
        return (bytes, http)
    }

    private enum BoundedProblemBody {
        case complete(Data)
        case exceedsLimit(
            prefix: Data,
            lookahead: UInt8,
            remainder: URLSession.AsyncBytes.Iterator
        )
    }

    private static func readBoundedProblemBody(
        response: HTTPURLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws -> BoundedProblemBody {
        var body = Data()
        if response.expectedContentLength > 0 {
            body.reserveCapacity(Int(response.expectedContentLength))
        }
        var iterator = bytes.makeAsyncIterator()
        while let byte = try await iterator.next() {
            guard body.count < SafeRetryDirective.maximumProblemBytes else {
                try Task.checkCancellation()
                return .exceedsLimit(
                    prefix: body,
                    lookahead: byte,
                    remainder: iterator
                )
            }
            body.append(byte)
        }
        try Task.checkCancellation()
        return .complete(body)
    }

    private static func httpResponse(
        _ response: HTTPURLResponse,
        body: Data
    ) -> LatchwayHTTPResponse {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String else { continue }
            headers[name] = String(describing: value)
        }
        return LatchwayHTTPResponse(
            statusCode: response.statusCode,
            headers: headers,
            body: body
        )
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
