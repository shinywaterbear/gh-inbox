import Foundation

/// A parsed JSON value, so each part of a response can be decoded on its own.
public enum JSON: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let i = try? c.decode(Int.self) {
      self = .int(i)
    } else if let d = try? c.decode(Double.self) {
      self = .double(d)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSON].self) {
      self = .array(a)
    } else {
      self = .object(try c.decode([String: JSON].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .int(let i): try c.encode(i)
    case .double(let d): try c.encode(d)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  /// `.null` for a missing key or a non-object; setting makes an object.
  public subscript(key: String) -> JSON {
    get {
      if case .object(let o) = self { return o[key] ?? .null }
      return .null
    }
    set {
      var o: [String: JSON] = [:]
      if case .object(let existing) = self { o = existing }
      o[key] = newValue
      self = .object(o)
    }
  }

  public subscript(index: Int) -> JSON {
    get {
      if case .array(let a) = self, a.indices.contains(index) { return a[index] }
      return .null
    }
    set {
      guard case .array(var a) = self, a.indices.contains(index) else { return }
      a[index] = newValue
      self = .array(a)
    }
  }

  public var isNull: Bool { self == .null }

  var string: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  /// A non-negative integer, as serde's `as_u64`.
  var unsigned: Int? {
    if case .int(let i) = self, i >= 0 { return i }
    return nil
  }

  public var text: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
  }

  /// Decodes `T` from this value; a failure is a readable sentence.
  func decode<T: Decodable>(_ type: T.Type) throws(GhError) -> T {
    do {
      return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    } catch let error as DecodingError {
      throw .parse(describe(error))
    } catch {
      throw .parse(String(describing: error))
    }
  }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(arrayLiteral elements: JSON...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSON)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}

func describe(_ error: DecodingError) -> String {
  func at(_ context: DecodingError.Context) -> String {
    let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
    return path.isEmpty ? "" : " at \(path.joined(separator: "."))"
  }
  switch error {
  case .keyNotFound(let key, let context):
    return "missing field `\(key.stringValue)`\(at(context))"
  case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
    return "\(context.debugDescription)\(at(context))"
  @unknown default:
    return String(describing: error)
  }
}
