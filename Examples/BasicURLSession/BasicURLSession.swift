import Foundation
import Latchway
import LatchwayAppAttest

func performRequest(identity: any LatchwayIdentityTokenProvider, body: Data) async throws -> Data {
    let baseURL = URL(string: "https://gateway.example.com")!
    let appAttest = LatchwayAppAttestProvider(
        applicationID: "app_01J00000000000000000000000",
        environment: "production"
    )
    let client = LatchwayClient(
        configuration: LatchwayConfiguration(
            baseURL: baseURL,
            applicationID: "app_01J00000000000000000000000",
            environment: "production",
            appVersion: "1.0.0",
            attestationProvider: appAttest
        ),
        identityTokenProvider: identity
    )
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/responses"))
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    try await client.authorize(&request, feature: "habit-assistant")
    let (data, response) = try await client.makeURLSession().data(for: request)
    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
        throw LatchwayError.invalidServerResponse
    }
    return data
}
