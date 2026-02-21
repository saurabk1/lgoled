import Foundation

struct LGTVDevice: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let macAddress: String?
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSONValue"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        if case .double(let value) = self { return Int(value) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

struct LGWebOSRequest: Codable {
    let type: String
    let id: String
    let uri: String?
    let payload: [String: JSONValue]?
}

struct LGWebOSResponse: Codable {
    let type: String
    let id: String?
    let payload: [String: JSONValue]?
    let error: String?
}

struct TVRuntimeState: Equatable {
    var volume: Int?
    var isMuted: Bool?
    var currentInput: String?
    var foregroundAppId: String?
    var powerState: String?
}

enum LGWebOSError: LocalizedError, Equatable {
    case notConnected
    case transport(String)
    case authFailed(String)
    case invalidResponse
    case timeout
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The TV is not connected."
        case .transport(let message):
            return "Network transport error: \(message)"
        case .authFailed(let message):
            return "TV pairing/authentication failed: \(message)"
        case .invalidResponse:
            return "Invalid response from TV."
        case .timeout:
            return "TV request timed out."
        case .unsupported(let feature):
            return "Feature not supported on this TV: \(feature)"
        }
    }
}
