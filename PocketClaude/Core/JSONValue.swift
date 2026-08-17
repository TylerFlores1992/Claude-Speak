import Foundation

/// A type-safe stand-in for "any JSON value".
///
/// Swift note for a TypeScript dev: Swift has no `any`/`unknown` that survives
/// `Codable`, so arbitrary JSON is modelled as an enum with one case per JSON
/// type. This matters here because we must round-trip Claude's `content` blocks
/// (including `thinking` blocks with their opaque `signature`) back to the API
/// **byte-for-byte unchanged** — decoding them into hand-written structs would
/// silently drop fields we don't know about and the API would reject the turn.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not valid JSON"
            )
        }
    }

    // MARK: - Encoding

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Encode whole numbers as integers so request bodies look natural
            // and so token counts / IDs don't come back as `1.0`.
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: - Convenience accessors

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Subscript into an object. Returns nil for any non-object.
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// A best-effort plain-text rendering, used when handing tool input to the
    /// UI or logging it.
    var displayText: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case .string(let value): return value
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
    }

    // MARK: - Construction helpers

    static func int(_ value: Int) -> JSONValue { .number(Double(value)) }

    /// Build a JSONValue from a Swift literal tree (`[String: Any]` / `[Any]`).
    /// Used to keep tool JSON-Schema definitions readable.
    static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let value as JSONValue: return value
        case let value as Bool: return .bool(value)
        case let value as Int: return .number(Double(value))
        case let value as Double: return .number(value)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(value.map { JSONValue.from($0) })
        case let value as [String: Any]:
            return .object(value.mapValues { JSONValue.from($0) })
        default: return .null
        }
    }
}
