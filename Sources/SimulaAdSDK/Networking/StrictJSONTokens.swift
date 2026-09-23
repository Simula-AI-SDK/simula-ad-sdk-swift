import Foundation

extension CodingUserInfoKey {
    static var simulaStrictJSONTokens: CodingUserInfoKey? {
        CodingUserInfoKey(rawValue: "com.simula.strict-json-tokens")
    }
    static var simulaVideoContract2: CodingUserInfoKey? {
        CodingUserInfoKey(rawValue: "com.simula.video-contract-2")
    }
}

func strictJSONPath(_ codingPath: [CodingKey], appending key: CodingKey? = nil) -> String {
    (codingPath + (key.map { [$0] } ?? [])).reduce(into: "") { result, component in
        if let index = component.intValue {
            result += "[\(index)]"
        } else {
            if !result.isEmpty { result += "." }
            result += component.stringValue
        }
    }
}

func exactJSONInteger(for decoder: Decoder, key: CodingKey) -> Int? {
    guard let userInfoKey = CodingUserInfoKey.simulaStrictJSONTokens,
          let tokens = decoder.userInfo[userInfoKey] as? [String: String],
          let token = tokens[strictJSONPath(decoder.codingPath, appending: key)],
          isCanonicalJSONInteger(token) else { return nil }
    return Int(token)
}

func isCanonicalJSONInteger(_ token: String) -> Bool {
    guard !token.isEmpty else { return false }
    let bytes = Array(token.utf8)
    var index = bytes.first == 45 ? 1 : 0
    guard index < bytes.count else { return false }
    if bytes[index] == 48 { return index + 1 == bytes.count }
    guard (49...57).contains(bytes[index]) else { return false }
    index += 1
    while index < bytes.count {
        guard (48...57).contains(bytes[index]) else { return false }
        index += 1
    }
    return true
}

/// Captures the original lexical token for every JSON scalar. Foundation's `JSONDecoder` accepts
/// `2.0` and `2e0` as `Int(2)`, so exact protocol markers must be checked before typed decoding.
struct StrictJSONTokenMap {
    private let bytes: [UInt8]
    private var index = 0
    private(set) var tokens: [String: String] = [:]

    init(data: Data) {
        bytes = Array(data)
    }

    static func parse(_ data: Data) -> [String: String] {
        var parser = StrictJSONTokenMap(data: data)
        guard parser.parseValue(path: "") else { return [:] }
        parser.skipWhitespace()
        return parser.index == parser.bytes.count ? parser.tokens : [:]
    }

    private mutating func parseValue(path: String) -> Bool {
        skipWhitespace()
        guard index < bytes.count else { return false }
        switch bytes[index] {
        case 123: return parseObject(path: path)
        case 91: return parseArray(path: path)
        case 34:
            let start = index
            guard parseString() != nil else { return false }
            tokens[path] = String(decoding: bytes[start..<index], as: UTF8.self)
            return true
        default:
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
                index += 1
            }
            guard index > start else { return false }
            tokens[path] = String(decoding: bytes[start..<index], as: UTF8.self)
            return true
        }
    }

    private mutating func parseObject(path: String) -> Bool {
        index += 1
        skipWhitespace()
        if consume(125) { return true }
        while index < bytes.count {
            guard let key = parseString() else { return false }
            skipWhitespace()
            guard consume(58) else { return false }
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            guard parseValue(path: childPath) else { return false }
            skipWhitespace()
            if consume(125) { return true }
            guard consume(44) else { return false }
            skipWhitespace()
        }
        return false
    }

    private mutating func parseArray(path: String) -> Bool {
        index += 1
        skipWhitespace()
        if consume(93) { return true }
        var item = 0
        while index < bytes.count {
            guard parseValue(path: "\(path)[\(item)]") else { return false }
            item += 1
            skipWhitespace()
            if consume(93) { return true }
            guard consume(44) else { return false }
            skipWhitespace()
        }
        return false
    }

    private mutating func parseString() -> String? {
        guard consume(34) else { return nil }
        let contentStart = index
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
                index += 1
            } else if byte == 92 {
                escaped = true
                index += 1
            } else if byte == 34 {
                let raw = Data(bytes[contentStart..<index])
                index += 1
                // JSON keys in this protocol are ASCII. Reject escaped keys rather than guessing a
                // path; typed decoding still handles the payload, but no exact marker is activated.
                guard !raw.contains(92) else { return nil }
                return String(data: raw, encoding: .utf8)
            } else {
                index += 1
            }
        }
        return nil
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ expected: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == expected else { return false }
        index += 1
        return true
    }
}

func decodeFullscreenPayload<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    let tokens = StrictJSONTokenMap.parse(data)
    let contract2 = tokens["video_contract"].flatMap { token in
        isCanonicalJSONInteger(token) ? Int(token) : nil
    } == 2
    let decoder = JSONDecoder()
    if let key = CodingUserInfoKey.simulaStrictJSONTokens { decoder.userInfo[key] = tokens }
    if let key = CodingUserInfoKey.simulaVideoContract2 { decoder.userInfo[key] = contract2 }
    return try decoder.decode(type, from: data)
}
