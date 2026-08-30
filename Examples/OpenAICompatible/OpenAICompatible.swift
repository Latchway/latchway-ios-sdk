import Foundation
import Latchway

func streamChat(
    client: LatchwayClient,
    baseURL: URL,
    receiveByte: @escaping @Sendable (UInt8) async throws -> Void
) async throws -> HTTPURLResponse {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(#"{"stream":true,"messages":[{"role":"user","content":"Hello"}]}"#.utf8)
    let stream = try await client
        .transport(feature: "habit-assistant")
        .bytes(for: request)
    guard (200 ..< 300).contains(stream.response.statusCode) else {
        stream.cancel()
        throw LatchwayError.invalidServerResponse
    }
    do {
        for try await byte in stream.bytes { try await receiveByte(byte) }
        stream.finish()
        return stream.response
    } catch {
        stream.cancel()
        throw error
    }
}
