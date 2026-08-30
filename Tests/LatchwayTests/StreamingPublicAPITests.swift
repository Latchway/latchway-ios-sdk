import Foundation
import Latchway
import XCTest

final class StreamingPublicAPITests: XCTestCase {
    func testStreamingTransportSurfaceIsPublic() {
        let operation: (LatchwayClient, URLRequest) async throws -> Void = { client, request in
            let transport: LatchwayFeatureTransport = client.transport(
                feature: "habit-assistant"
            )
            let stream: LatchwayStreamingResponse = try await transport.bytes(
                for: request
            )
            _ = stream.response
            _ = stream.bytes.makeAsyncIterator()
            stream.finish()
            stream.cancel()
        }
        _ = operation
    }
}
