import Foundation

public struct LightChannels: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let green = LightChannels(rawValue: 1 << 0)
    public static let yellow = LightChannels(rawValue: 1 << 1)
    public static let red = LightChannels(rawValue: 1 << 2)
    public static let all = LightChannels(rawValue: 0xFF)
}

public enum LightAction: String, Sendable {
    case on
    case off
    case blink
}

public struct LightCommand: Equatable, Sendable {
    public var channels: LightChannels
    public var action: LightAction
    public var only: Bool
    public var count: UInt16?
    public var frequencyMilliseconds: UInt16?
    public var fadeMilliseconds: UInt16?

    public init(
        channels: LightChannels,
        action: LightAction,
        only: Bool = false,
        count: UInt16? = nil,
        frequencyMilliseconds: UInt16? = nil,
        fadeMilliseconds: UInt16? = nil
    ) {
        self.channels = channels
        self.action = action
        self.only = only
        self.count = count
        self.frequencyMilliseconds = frequencyMilliseconds
        self.fadeMilliseconds = fadeMilliseconds
    }
}

public enum PersistentParameter: String, CaseIterable, Sendable {
    case brightness = "led.brightness"
    case frequency = "led.frequency"
    case fadeTime = "led.fadetime"
    case advertisingTimeout = "ble.advtimeout"
}

public enum DeviceInstruction: Equatable, Sendable {
    case light(LightCommand)
    case wait(milliseconds: UInt32)
    case read(PersistentParameter)
    case write(PersistentParameter, value: Int)
}

public enum CommandParseError: Error, Equatable, CustomStringConvertible {
    case empty
    case unknownCommand(String)
    case missingArgument(String)
    case invalidValue(String)
    case outOfRange(String)

    public var description: String {
        switch self {
        case .empty: return "Command is empty"
        case .unknownCommand(let value): return "Unknown command: \(value)"
        case .missingArgument(let value): return "Missing argument: \(value)"
        case .invalidValue(let value): return "Invalid value: \(value)"
        case .outOfRange(let value): return "Value is out of range: \(value)"
        }
    }
}

public enum NorthboundCompiler {
    public static func compileScript(_ script: String) throws -> [DeviceInstruction] {
        let clauses = script
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !clauses.isEmpty else { throw CommandParseError.empty }
        return try clauses.map(compileLine)
    }

    public static func compileLine(_ line: String) throws -> DeviceInstruction {
        var tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let verb = tokens.first?.lowercased() else { throw CommandParseError.empty }
        tokens.removeFirst()

        switch verb {
        case "led":
            return .light(try parseLight(tokens))
        case "wait":
            guard let raw = tokens.first else { throw CommandParseError.missingArgument("duration") }
            return .wait(milliseconds: try parseDuration(raw, minimum: 0, maximum: 86_400_000))
        case "read":
            guard let raw = tokens.first, let parameter = PersistentParameter(rawValue: raw.lowercased()) else {
                throw CommandParseError.invalidValue(tokens.first ?? "parameter")
            }
            return .read(parameter)
        case "write":
            guard tokens.count >= 2 else { throw CommandParseError.missingArgument("parameter and value") }
            guard let parameter = PersistentParameter(rawValue: tokens[0].lowercased()) else {
                throw CommandParseError.invalidValue(tokens[0])
            }
            let value = try parseParameterValue(tokens[1], parameter: parameter)
            return .write(parameter, value: value)
        default:
            throw CommandParseError.unknownCommand(verb)
        }
    }

    private static func parseLight(_ tokens: [String]) throws -> LightCommand {
        guard tokens.count >= 2 else { throw CommandParseError.missingArgument("color and action") }
        let channels = try parseChannels(tokens[0])
        guard let action = LightAction(rawValue: tokens[1].lowercased()) else {
            throw CommandParseError.invalidValue(tokens[1])
        }

        var command = LightCommand(channels: channels, action: action)
        var index = 2
        while index < tokens.count {
            switch tokens[index].lowercased() {
            case "--only":
                command.only = true
                index += 1
            case "--count":
                guard index + 1 < tokens.count else { throw CommandParseError.missingArgument("--count value") }
                command.count = try parseUInt16(tokens[index + 1], minimum: 0, maximum: UInt16(UInt8.max))
                index += 2
            case "--freq", "--frequency":
                guard index + 1 < tokens.count else { throw CommandParseError.missingArgument("--freq value") }
                command.frequencyMilliseconds = UInt16(try parseDuration(tokens[index + 1], minimum: 200, maximum: 5_000))
                index += 2
            case "--fade":
                guard index + 1 < tokens.count else { throw CommandParseError.missingArgument("--fade value") }
                command.fadeMilliseconds = UInt16(try parseDuration(tokens[index + 1], minimum: 0, maximum: 5_000))
                index += 2
            default:
                throw CommandParseError.unknownCommand(tokens[index])
            }
        }
        return command
    }

    private static func parseChannels(_ raw: String) throws -> LightChannels {
        var result: LightChannels = []
        for token in raw.lowercased().split(separator: "+") {
            switch token {
            case "red": result.insert(.red)
            case "yellow", "amber": result.insert(.yellow)
            case "green": result.insert(.green)
            case "all": result.formUnion(.all)
            default: throw CommandParseError.invalidValue(String(token))
            }
        }
        guard !result.isEmpty else { throw CommandParseError.invalidValue(raw) }
        return result
    }

    private static func parseParameterValue(_ raw: String, parameter: PersistentParameter) throws -> Int {
        switch parameter {
        case .brightness:
            return Int(try parseUInt16(raw.replacingOccurrences(of: "%", with: ""), minimum: 5, maximum: 100))
        case .frequency, .fadeTime:
            return Int(try parseDuration(raw, minimum: parameter == .frequency ? 200 : 0, maximum: 5_000))
        case .advertisingTimeout:
            let seconds = raw.lowercased().hasSuffix("s") ? String(raw.dropLast()) : raw
            guard let value = UInt16(seconds), value == 0 || (30...240).contains(value) else {
                throw CommandParseError.outOfRange(raw)
            }
            return Int(value)
        }
    }

    private static func parseDuration(_ raw: String, minimum: UInt32, maximum: UInt32) throws -> UInt32 {
        let lower = raw.lowercased()
        let milliseconds: Double
        if lower.hasSuffix("ms") {
            guard let value = Double(lower.dropLast(2)) else { throw CommandParseError.invalidValue(raw) }
            milliseconds = value
        } else if lower.hasSuffix("s") {
            guard let value = Double(lower.dropLast()) else { throw CommandParseError.invalidValue(raw) }
            milliseconds = value * 1_000
        } else {
            guard let value = Double(lower) else { throw CommandParseError.invalidValue(raw) }
            milliseconds = value
        }
        guard milliseconds.rounded() == milliseconds, milliseconds >= Double(minimum), milliseconds <= Double(maximum) else {
            throw CommandParseError.outOfRange(raw)
        }
        return UInt32(milliseconds)
    }

    private static func parseUInt16(_ raw: String, minimum: UInt16, maximum: UInt16) throws -> UInt16 {
        guard let value = UInt32(raw), value >= UInt32(minimum), value <= UInt32(maximum) else {
            throw CommandParseError.outOfRange(raw)
        }
        return UInt16(value)
    }
}
