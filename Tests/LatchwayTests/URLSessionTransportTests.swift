import Foundation
@testable import Latchway
import XCTest

final class URLSessionTransportTests: XCTestCase {
    func testBufferedTransportEnforcesResponseMemoryBound() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = LatchwayURLSessionTransport(
            session: session,
            maximumResponseBytes: 1_024
        )
        let request = URLRequest(url: URL(string: "https://gateway.example.test/v1/responses")!)

        do {
            _ = try await transport.send(request)
            XCTFail("An oversized buffered response must be rejected")
        } catch let error as LatchwayError {
            XCTAssertEqual(error, .invalidServerResponse)
        } catch {
            XCTFail("Expected a stable LatchwayError, got \(type(of: error))")
        }
    }

    // FW-SEC-103
    func testFWSEC103RedirectDestinationIsRejectedBeforeCredentialRedispatch() async throws {
        let originalURL = try XCTUnwrap(
            URL(string: "https://gateway.example.test/v1/responses")
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: originalURL,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "/v1/responses/redirected"]
        ))
        let delegate = LatchwayRedirectRejectingDelegate()

        for destination in [
            "https://gateway.example.test/v1/responses/redirected",
            "https://attacker.example/v1/responses",
        ] {
            let redirected = URLRequest(url: try XCTUnwrap(URL(string: destination)))
            let followed = await withCheckedContinuation { continuation in
                delegate.urlSession(
                    session,
                    task: task,
                    willPerformHTTPRedirection: response,
                    newRequest: redirected,
                    completionHandler: { continuation.resume(returning: $0) }
                )
            }
            XCTAssertNil(followed, "Latchway must never redispatch a URL-bound DPoP proof")
        }
    }
}

private final class OversizedResponseURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: LatchwayError.invalidServerResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 2_048))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
