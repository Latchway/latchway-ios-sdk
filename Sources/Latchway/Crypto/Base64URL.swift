import Foundation

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) throws -> Data {
        guard !value.isEmpty, !value.contains("=") else { throw LatchwayError.invalidServerResponse }
        var standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch standard.count % 4 {
        case 0: break
        case 2: standard += "=="
        case 3: standard += "="
        default: throw LatchwayError.invalidServerResponse
        }
        guard let data = Data(base64Encoded: standard), encode(data) == value else {
            throw LatchwayError.invalidServerResponse
        }
        return data
    }
}

extension Data {
    var latchwayHex: String { map { String(format: "%02x", $0) }.joined() }
}
