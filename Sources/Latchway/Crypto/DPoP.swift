import CryptoKit
import Foundation

public struct LatchwayDPoPProofFactory: Sendable {
    private let key: any LatchwayInstallationKey
    private let clock: any LatchwayClock

    public init(key: any LatchwayInstallationKey, clock: any LatchwayClock = LatchwaySystemClock()) {
        self.key = key
        self.clock = clock
    }

    public func proof(
        method: String,
        url: URL,
        accessToken: String? = nil,
        nonce: String? = nil,
        proofID: UUID = UUID()
    ) async throws -> String {
        let method = method.uppercased()
        guard !method.isEmpty else { throw LatchwayError.invalidRequest("HTTP method is required") }
        let htu = try Self.normalizedHTU(url)
        let jwk = try await validatedJWK()

        struct Header: Encodable {
            let typ = "dpop+jwt"
            let alg = "ES256"
            let jwk: LatchwayPublicJWK
        }
        struct Claims: Encodable {
            let htm: String
            let htu: String
            let iat: Int64
            let jti: String
            let ath: String?
            let nonce: String?
        }

        let header = try Self.encodeJSON(Header(jwk: jwk))
        let accessHash = accessToken.map { Base64URL.encode(Data(SHA256.hash(data: Data($0.utf8)))) }
        let claims = try Self.encodeJSON(Claims(
            htm: method,
            htu: htu,
            iat: Int64((await clock.now()).timeIntervalSince1970.rounded(.down)),
            jti: proofID.uuidString.lowercased(),
            ath: accessHash,
            nonce: nonce
        ))
        let signingInput = Base64URL.encode(header) + "." + Base64URL.encode(claims)
        let signature = try await key.sign(Data(signingInput.utf8))
        guard signature.count == 64 else { throw LatchwayError.keyStorageFailure }
        return signingInput + "." + Base64URL.encode(signature)
    }

    public func thumbprint() async throws -> String {
        let jwk = try await validatedJWK()
        let canonical = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"\(jwk.x)\",\"y\":\"\(jwk.y)\"}"
        return Base64URL.encode(Data(SHA256.hash(data: Data(canonical.utf8))))
    }

    private func validatedJWK() async throws -> LatchwayPublicJWK {
        let jwk = try await key.publicJWK()
        guard jwk.keyType == "EC",
              jwk.curve == "P-256",
              jwk.x.utf8.count == 43,
              jwk.y.utf8.count == 43,
              let x = try? Base64URL.decode(jwk.x),
              let y = try? Base64URL.decode(jwk.y),
              x.count == 32,
              y.count == 32
        else { throw LatchwayError.keyStorageFailure }
        return jwk
    }

    public static func normalizedHTU(_ url: URL) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme,
              let rawHost = components.host,
              components.user == nil,
              components.password == nil
        else { throw LatchwayError.invalidRequest("An absolute HTTP URL without user information is required") }

        let scheme = rawScheme.lowercased()
        guard scheme == "https" || scheme == "http" else {
            throw LatchwayError.invalidRequest("Only HTTP and HTTPS URLs are supported")
        }
        guard rawHost.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw LatchwayError.invalidRequest("The URL host must be ASCII")
        }
        var host = rawHost.lowercased()
        if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }
        if let port = components.port, !((scheme == "http" && port == 80) || (scheme == "https" && port == 443)) {
            guard (1 ... 65_535).contains(port) else { throw LatchwayError.invalidRequest("The URL port is invalid") }
            host += ":\(port)"
        }

        components.query = nil
        components.fragment = nil
        let normalizedPath = try normalizePath(components.percentEncodedPath)
        return "\(scheme)://\(host)\(normalizedPath)"
    }

    private static func encodeJSON(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(value) }
        catch { throw LatchwayError.invalidRequest("The DPoP proof could not be encoded") }
    }

    private static func normalizePath(_ escapedPath: String) throws -> String {
        let source = escapedPath.isEmpty ? "/" : escapedPath
        var normalized = ""
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] != "%" {
                normalized.append(source[index])
                index = source.index(after: index)
                continue
            }
            guard let first = source.index(index, offsetBy: 1, limitedBy: source.endIndex),
                  let second = source.index(index, offsetBy: 2, limitedBy: source.endIndex),
                  second < source.endIndex,
                  let value = UInt8(String(source[first ... second]), radix: 16)
            else { throw LatchwayError.invalidRequest("The URL path has invalid percent encoding") }
            if isUnreserved(value) {
                normalized.append(Character(UnicodeScalar(value)))
            } else {
                normalized += String(format: "%%%02X", value)
            }
            index = source.index(after: second)
        }
        let clean = removeDotSegments(normalized)
        if clean.isEmpty { return "/" }
        return clean.hasPrefix("/") ? clean : "/" + clean
    }

    private static func removeDotSegments(_ value: String) -> String {
        var input = value
        var output = ""
        while !input.isEmpty {
            if input.hasPrefix("../") { input.removeFirst(3) }
            else if input.hasPrefix("./") { input.removeFirst(2) }
            else if input.hasPrefix("/./") { input = "/" + input.dropFirst(3) }
            else if input == "/." { input = "/" }
            else if input.hasPrefix("/../") {
                input = "/" + input.dropFirst(4)
                output = removeLastSegment(output)
            } else if input == "/.." {
                input = "/"
                output = removeLastSegment(output)
            } else if input == "." || input == ".." { input = "" }
            else {
                let searchStart = input.hasPrefix("/") ? input.index(after: input.startIndex) : input.startIndex
                if let slash = input[searchStart...].firstIndex(of: "/") {
                    output += input[..<slash]
                    input = String(input[slash...])
                } else {
                    output += input
                    input = ""
                }
            }
        }
        return output
    }

    private static func removeLastSegment(_ value: String) -> String {
        guard let slash = value.lastIndex(of: "/") else { return "" }
        return String(value[..<slash])
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || [45, 46, 95, 126].contains(byte)
    }
}
