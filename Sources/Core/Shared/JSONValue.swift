import Foundation

/// Minimal, Sendable JSON tree. Samsung Cloud records are loosely typed
/// (numbers arrive as numbers or strings), so we keep the raw tree and read
/// through tolerant accessors instead of fixed Codable structs.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Accepts 12, 12.0, "12" and true/false (as 1/0).
    public var int: Int64? {
        switch self {
        case .number(let value): return value.isFinite ? Int64(value) : nil
        case .string(let value): return Int64(value) ?? Double(value).flatMap { $0.isFinite ? Int64($0) : nil }
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .number, .string: return int.map { $0 == 1 }
        default: return nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue {
        object?[key] ?? .null
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Keep integral values integral so Samsung receives 123 rather than 123.0.
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 { try container.encode(Int64(value)) }
            else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public extension JSONValue {
    init(_ value: Int64) { self = .number(Double(value)) }
    init(_ value: Int) { self = .number(Double(value)) }
    init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
}
