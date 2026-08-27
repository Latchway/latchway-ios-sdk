@preconcurrency import Foundation

public struct LatchwayURLSessionTransport: LatchwayHTTPTransport {
    private let session: URLSession
    private let maximumResponseBytes: Int

    public init(session: URLSession = .shared, maximumResponseBytes: Int = 1_048_576) {
        self.session = session
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func send(_ request: URLRequest) async throws -> LatchwayHTTPResponse {
        do {
            guard maximumResponseBytes > 0 else { throw LatchwayError.invalidServerResponse }
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw LatchwayError.invalidServerResponse
            }
            let expectedLength = response.expectedContentLength
            guard expectedLength <= 0 || expectedLength <= Int64(maximumResponseBytes) else {
                throw LatchwayError.invalidServerResponse
            }
            var data = Data()
            if expectedLength > 0 {
                data.reserveCapacity(Int(expectedLength))
            }
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw LatchwayError.invalidServerResponse
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            var headers: [String: String] = [:]
            for (name, value) in response.allHeaderFields {
                guard let name = name as? String else { continue }
                headers[name] = String(describing: value)
            }
            return LatchwayHTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
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
}

/// Immutable Foundation delegate. The unchecked conformance bridges NSObject's
/// legacy declaration; the instance has no mutable state to isolate.
final class LatchwayRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // A DPoP proof binds the original method and URL. Following even a
        // same-origin redirect would send a proof that cannot authenticate the
        // redirected target; a cross-origin redirect could also expose bearer
        // material to an unintended authority.
        completionHandler(nil)
    }
}

enum LatchwayURLSessionFactory {
    static func make() -> URLSession {
        URLSession(
            configuration: .latchwayEphemeral(),
            delegate: LatchwayRedirectRejectingDelegate(),
            delegateQueue: nil
        )
    }
}

extension URLSessionConfiguration {
    static func latchwayEphemeral() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        configuration.waitsForConnectivity = true
        return configuration
    }
}
