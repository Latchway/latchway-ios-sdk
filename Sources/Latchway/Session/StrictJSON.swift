import Foundation

enum StrictJSON {
    static func validate(_ data: Data, maximumDepth: Int = 64, maximumValues: Int = 100_000) throws {
        var parser = Parser(bytes: Array(data), maximumDepth: maximumDepth, maximumValues: maximumValues)
        try parser.parse()
    }

    private struct Parser {
        let bytes: [UInt8]
        let maximumDepth: Int
        let maximumValues: Int
        var index = 0
        var values = 0

        mutating func parse() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else { throw LatchwayError.invalidServerResponse }
        }

        mutating func parseValue(depth: Int) throws {
            guard depth <= maximumDepth, index < bytes.count else { throw LatchwayError.invalidServerResponse }
            values += 1
            guard values <= maximumValues else { throw LatchwayError.invalidServerResponse }
            switch bytes[index] {
            case 0x7B: try parseObject(depth: depth + 1)
            case 0x5B: try parseArray(depth: depth + 1)
            case 0x22: _ = try parseString()
            case 0x74: try consume("true")
            case 0x66: try consume("false")
            case 0x6E: try consume("null")
            case 0x2D, 0x30 ... 0x39: try parseNumber()
            default: throw LatchwayError.invalidServerResponse
            }
        }

        mutating func parseObject(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consumeIf(0x7D) { return }
            var members = Set<String>()
            while true {
                guard index < bytes.count, bytes[index] == 0x22 else { throw LatchwayError.invalidServerResponse }
                let key = try parseString()
                guard members.insert(key).inserted else { throw LatchwayError.invalidServerResponse }
                skipWhitespace()
                guard consumeIf(0x3A) else { throw LatchwayError.invalidServerResponse }
                skipWhitespace()
                try parseValue(depth: depth)
                skipWhitespace()
                if consumeIf(0x7D) { return }
                guard consumeIf(0x2C) else { throw LatchwayError.invalidServerResponse }
                skipWhitespace()
            }
        }

        mutating func parseArray(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consumeIf(0x5D) { return }
            while true {
                try parseValue(depth: depth)
                skipWhitespace()
                if consumeIf(0x5D) { return }
                guard consumeIf(0x2C) else { throw LatchwayError.invalidServerResponse }
                skipWhitespace()
            }
        }

        mutating func parseString() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    let data = Data(bytes[start ..< index])
                    guard let value = try? JSONDecoder().decode(String.self, from: data) else {
                        throw LatchwayError.invalidServerResponse
                    }
                    return value
                }
                if byte < 0x20 { throw LatchwayError.invalidServerResponse }
                if byte == 0x5C {
                    index += 1
                    guard index < bytes.count else { throw LatchwayError.invalidServerResponse }
                    if bytes[index] == 0x75 {
                        guard index + 4 < bytes.count else { throw LatchwayError.invalidServerResponse }
                        for position in (index + 1) ... (index + 4) where !Self.isHex(bytes[position]) {
                            throw LatchwayError.invalidServerResponse
                        }
                        index += 5
                        continue
                    }
                    guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(bytes[index]) else {
                        throw LatchwayError.invalidServerResponse
                    }
                }
                index += 1
            }
            throw LatchwayError.invalidServerResponse
        }

        mutating func parseNumber() throws {
            if consumeIf(0x2D), index == bytes.count { throw LatchwayError.invalidServerResponse }
            if consumeIf(0x30) {
                if index < bytes.count, Self.isDigit(bytes[index]) { throw LatchwayError.invalidServerResponse }
            } else {
                guard index < bytes.count, (0x31 ... 0x39).contains(bytes[index]) else { throw LatchwayError.invalidServerResponse }
                repeat { index += 1 } while index < bytes.count && Self.isDigit(bytes[index])
            }
            if consumeIf(0x2E) {
                guard index < bytes.count, Self.isDigit(bytes[index]) else { throw LatchwayError.invalidServerResponse }
                repeat { index += 1 } while index < bytes.count && Self.isDigit(bytes[index])
            }
            if index < bytes.count, (bytes[index] == 0x65 || bytes[index] == 0x45) {
                index += 1
                if index < bytes.count, (bytes[index] == 0x2B || bytes[index] == 0x2D) { index += 1 }
                guard index < bytes.count, Self.isDigit(bytes[index]) else { throw LatchwayError.invalidServerResponse }
                repeat { index += 1 } while index < bytes.count && Self.isDigit(bytes[index])
            }
        }

        mutating func consume(_ literal: StaticString) throws {
            let expected = Array(String(describing: literal).utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index ..< index + expected.count]) == expected
            else { throw LatchwayError.invalidServerResponse }
            index += expected.count
        }

        mutating func consumeIf(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        static func isDigit(_ byte: UInt8) -> Bool { (0x30 ... 0x39).contains(byte) }
        static func isHex(_ byte: UInt8) -> Bool {
            (0x30 ... 0x39).contains(byte) || (0x41 ... 0x46).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }
}
