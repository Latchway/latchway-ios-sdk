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
    try await client.authorize(&request, feature: "habit-assistant")
    let (bytes, response) = try await client.makeURLSession().bytes(for: request)
    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
        throw LatchwayError.invalidServerResponse
    }
    for try await byte in bytes { try await receiveByte(byte) }
    return http
}
