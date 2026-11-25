import Foundation

/// 宽松类型的 JSON。同一字段在酷安不同接口里可能是字符串也可能是数字，
/// 所以模型读取时不严格区分类型。
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(_ any: Any?) {
        switch any {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as [Any]:
            self = .array(value.map(JSON.init))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSON.init))
        default:
            self = .null
        }
    }

    public static func parse(_ data: Data) -> JSON? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JSON(object)
    }

    public static func parse(_ text: String) -> JSON? { parse(Data(text.utf8)) }

    public subscript(key: String) -> JSON {
        if case .object(let object) = self { return object[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSON {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return .null
    }

    public var isNull: Bool { self == .null }

    /// 字符串，或转成文本的数字 / 布尔值。
    public var string: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
            return String(value)
        case .bool(let value): return value ? "1" : "0"
        default: return nil
        }
    }

    /// 仅返回非空文本。
    public var text: String? {
        guard let value = string, !value.isEmpty else { return nil }
        return value
    }

    public var int: Int? {
        switch self {
        case .number(let value): return value.isFinite ? Int(value) : nil
        case .string(let value): return Int(value.trimmingCharacters(in: .whitespaces))
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value): return ["1", "true"].contains(value.lowercased())
        default: return nil
        }
    }

    public var array: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.foundationObject)
        case .object(let value): return value.mapValues(\.foundationObject)
        }
    }

    public func serialized(pretty: Bool = false) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: foundationObject,
            options: pretty ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed] : [.fragmentsAllowed])
    }
}
