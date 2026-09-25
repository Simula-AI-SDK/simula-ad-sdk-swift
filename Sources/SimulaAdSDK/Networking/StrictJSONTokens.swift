import Foundation

let fullscreenResponseMaximumBytes = 10 * 1024 * 1024
let strictJSONMaximumNestingDepth = 64

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

/// Captures original lexical tokens only for protocol fields that require exact integers.
/// Foundation's `JSONDecoder` accepts `2.0` and `2e0` as `Int(2)`, while retaining every scalar
/// would duplicate large inline HTML strings. Parsing is depth-bounded before Foundation decoding.
struct StrictJSONTokenMap {
    private let bytes: [UInt8]
    private var index = 0
    private(set) var tokens: [String: String] = [:]

    init(data: Data) {
        bytes = Array(data)
    }

    static func parse(_ data: Data) -> [String: String]? {
        guard data.count <= fullscreenResponseMaximumBytes else { return nil }
        var parser = StrictJSONTokenMap(data: data)
        guard parser.parseValue(path: "", depth: 0) else { return nil }
        parser.skipWhitespace()
        return parser.index == parser.bytes.count ? parser.tokens : nil
    }

    private mutating func parseValue(path: String, depth: Int) -> Bool {
        guard depth <= strictJSONMaximumNestingDepth else { return false }
        skipWhitespace()
        guard index < bytes.count else { return false }
        switch bytes[index] {
        case 123: return parseObject(path: path, depth: depth)
        case 91: return parseArray(path: path, depth: depth)
        case 34:
            // Exact-token fields are numeric. Skip all string values in-place so large inline
            // `rendered_html` values never create a second Data/String allocation.
            return skipString()
        default:
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
                index += 1
            }
            guard index > start else { return false }
            captureToken(path: path, start: start)
            return true
        }
    }

    private mutating func parseObject(path: String, depth: Int) -> Bool {
        index += 1
        skipWhitespace()
        if consume(125) { return true }
        while index < bytes.count {
            guard let key = parseKey() else { return false }
            skipWhitespace()
            guard consume(58) else { return false }
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            guard parseValue(path: childPath, depth: depth + 1) else { return false }
            skipWhitespace()
            if consume(125) { return true }
            guard consume(44) else { return false }
            skipWhitespace()
        }
        return false
    }

    private mutating func parseArray(path: String, depth: Int) -> Bool {
        index += 1
        skipWhitespace()
        if consume(93) { return true }
        var item = 0
        while index < bytes.count {
            guard parseValue(path: "\(path)[\(item)]", depth: depth + 1) else { return false }
            item += 1
            skipWhitespace()
            if consume(93) { return true }
            guard consume(44) else { return false }
            skipWhitespace()
        }
        return false
    }

    private mutating func captureToken(path: String, start: Int) {
        guard Self.requiresExactToken(path) else { return }
        tokens[path] = String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private static func requiresExactToken(_ path: String) -> Bool {
        if path == "video_contract" || path == "ad_behavior.skoverlay.delay_seconds" {
            return true
        }
        let parts = path.split(separator: ".").map(String.init)
        if parts.count == 3 {
            return parts[0] == "creative"
                && isIndexed(parts[1], name: "segments")
                && parts[2] == "clip_index"
        }
        if parts.count == 4 {
            let fallbackOverlay = isIndexed(parts[0], name: "ads")
                && parts[1] == "ad_behavior"
                && parts[2] == "skoverlay"
                && parts[3] == "delay_seconds"
            let fallbackSegment = isIndexed(parts[0], name: "ads")
                && parts[1] == "creative"
                && isIndexed(parts[2], name: "segments")
                && parts[3] == "clip_index"
            return fallbackOverlay || fallbackSegment
        }
        return false
    }

    private static func isIndexed(_ component: String, name: String) -> Bool {
        let prefix = "\(name)["
        guard component.hasPrefix(prefix), component.hasSuffix("]") else { return false }
        let start = component.index(component.startIndex, offsetBy: prefix.count)
        let end = component.index(before: component.endIndex)
        return start < end && component[start..<end].allSatisfy(\.isNumber)
    }

    private mutating func parseKey() -> String? {
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
                // Exact protocol keys are ASCII. An escaped key gets an intentionally non-matching
                // path while typed decoding still handles it.
                if raw.contains(92) { return "__escaped_json_key__" }
                return String(data: raw, encoding: .utf8)
            } else {
                index += 1
            }
        }
        return nil
    }

    private mutating func skipString() -> Bool {
        guard consume(34) else { return false }
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 92 {
                escaped = true
            } else if byte == 34 {
                return true
            }
        }
        return false
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
    guard data.count <= fullscreenResponseMaximumBytes,
          let tokens = StrictJSONTokenMap.parse(data) else {
        throw SimulaAPIError.invalidResponse
    }
    let contract2 = tokens["video_contract"].flatMap { token in
        isCanonicalJSONInteger(token) ? Int(token) : nil
    } == 2
    let decoder = JSONDecoder()
    if let key = CodingUserInfoKey.simulaStrictJSONTokens { decoder.userInfo[key] = tokens }
    if let key = CodingUserInfoKey.simulaVideoContract2 { decoder.userInfo[key] = contract2 }
    return try decoder.decode(type, from: data)
}
