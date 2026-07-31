import Foundation

/// A JSON value used to preserve arbitrary fields posted by AI-agent integrations.
public enum WebConsoleJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: WebConsoleJSONValue])
    case array([WebConsoleJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: WebConsoleJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([WebConsoleJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

/// The JSON object delivered to the `/api/event` handler.
///
/// Unknown fields are retained so integrations can evolve without requiring a
/// server update. Common field names are available as convenience properties.
public struct WebConsoleEvent: Codable, Equatable, Sendable {
    public var payload: [String: WebConsoleJSONValue]

    public init(payload: [String: WebConsoleJSONValue]) {
        self.payload = payload
    }

    public init(
        name: String,
        agent: String? = nil,
        session: String? = nil,
        cwd: String? = nil,
        message: String? = nil,
        command: String? = nil
    ) {
        var payload: [String: WebConsoleJSONValue] = ["event": .string(name)]
        if let agent { payload["agent"] = .string(agent) }
        if let session { payload["session"] = .string(session) }
        if let cwd { payload["cwd"] = .string(cwd) }
        if let message { payload["message"] = .string(message) }
        if let command { payload["command"] = .string(command) }
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        payload = try container.decode([String: WebConsoleJSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(payload)
    }

    public var name: String? {
        string(for: ["event", "name", "hook_event_name", "hookEventName"])
    }

    public var agent: String? { string(for: ["agent"]) }
    public var session: String? { string(for: ["session", "session_id", "sessionId"]) }
    public var cwd: String? { string(for: ["cwd"]) }
    public var message: String? { string(for: ["message"]) }
    public var command: String? { string(for: ["command", "cmd"]) }

    private func string(for keys: [String]) -> String? {
        keys.lazy.compactMap { payload[$0]?.stringValue }.first
    }
}

public struct WebConsoleLogEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case info
        case success
        case warning
        case error
    }

    public var timestamp: Date
    public var source: String
    public var message: String
    public var kind: Kind

    public init(
        timestamp: Date = Date(),
        source: String,
        message: String,
        kind: Kind = .info
    ) {
        self.timestamp = timestamp
        self.source = source
        self.message = message
        self.kind = kind
    }
}

/// Snapshot rendered by the local console and returned by `/api/status`.
public struct WebConsoleStatus: Codable, Equatable, Sendable {
    public var connected: Bool
    public var deviceName: String?
    public var serialNumber: String?
    public var batteryLevel: Int?
    public var lightState: String
    public var serviceMessage: String
    public var activeAgent: String?
    public var recentEvents: [WebConsoleLogEntry]

    public init(
        connected: Bool,
        deviceName: String? = nil,
        serialNumber: String? = nil,
        batteryLevel: Int? = nil,
        lightState: String = "Unknown",
        serviceMessage: String = "PromLight service is running.",
        activeAgent: String? = nil,
        recentEvents: [WebConsoleLogEntry] = []
    ) {
        self.connected = connected
        self.deviceName = deviceName
        self.serialNumber = serialNumber
        self.batteryLevel = batteryLevel.map { min(100, max(0, $0)) }
        self.lightState = lightState
        self.serviceMessage = serviceMessage
        self.activeAgent = activeAgent
        self.recentEvents = recentEvents
    }
}

/// Outcome returned by command and event handlers.
public struct WebConsoleActionResult: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var message: String

    public init(accepted: Bool = true, message: String) {
        self.accepted = accepted
        self.message = message
    }
}

public typealias WebConsoleStatusProvider = @Sendable () throws -> WebConsoleStatus
public typealias WebConsoleCommandHandler = @Sendable (String) throws -> WebConsoleActionResult
public typealias WebConsoleEventHandler = @Sendable (WebConsoleEvent) throws -> WebConsoleActionResult
