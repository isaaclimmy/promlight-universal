import Foundation

public struct AtomicFrame: Equatable, Sendable {
    public static let startOfFrame: [UInt8] = [0x5E, 0x5E]
    public static let reportID: CFIndex = 2
    public static let reportDataLength = 64
    public static let maximumPayloadLength = 59

    public var code: UInt8
    public var payload: [UInt8]

    public init(code: UInt8, payload: [UInt8] = []) throws {
        guard payload.count <= Self.maximumPayloadLength else {
            throw AtomicProtocolError.payloadTooLarge(payload.count)
        }
        self.code = code
        self.payload = payload
    }

    public var encoded: [UInt8] {
        let length = UInt8(payload.count + 2)
        var bytes = Self.startOfFrame + [length, code] + payload
        bytes.append(bytes.reduce(0, ^))
        return bytes
    }

    public var outputReport: [UInt8] {
        encoded + Array(repeating: 0, count: Self.reportDataLength - encoded.count)
    }

    public static func decode(from report: some Collection<UInt8>) throws -> AtomicFrame {
        let bytes = Array(report)
        guard let start = findStart(in: bytes), start + 3 < bytes.count else {
            throw AtomicProtocolError.frameNotFound
        }
        let frameLength = Int(bytes[start + 2])
        guard frameLength >= 2 else { throw AtomicProtocolError.invalidLength(frameLength) }
        let end = start + 3 + frameLength
        guard end <= bytes.count else { throw AtomicProtocolError.truncated }
        let framed = Array(bytes[start..<end])
        guard framed.reduce(0, ^) == 0 else { throw AtomicProtocolError.invalidChecksum }
        return try AtomicFrame(code: framed[3], payload: Array(framed.dropFirst(4).dropLast()))
    }

    private static func findStart(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2 else { return nil }
        for index in 0..<(bytes.count - 1) where bytes[index] == 0x5E && bytes[index + 1] == 0x5E {
            return index
        }
        return nil
    }
}

public enum AtomicProtocolError: Error, Equatable, CustomStringConvertible {
    case payloadTooLarge(Int)
    case frameNotFound
    case invalidLength(Int)
    case truncated
    case invalidChecksum
    case deviceError(code: UInt8, detail: UInt8?)
    case unexpectedResponse(expected: UInt8, actual: UInt8)
    case invalidResponsePayload

    public var description: String {
        switch self {
        case .payloadTooLarge(let count): return "HID payload is too large (\(count) bytes)"
        case .frameNotFound: return "No PromLight frame was found in the HID report"
        case .invalidLength(let length): return "Invalid PromLight frame length: \(length)"
        case .truncated: return "The PromLight frame is truncated"
        case .invalidChecksum: return "The PromLight frame checksum is invalid"
        case .deviceError(_, let detail): return "PromLight rejected the command: \(Self.errorName(detail))"
        case .unexpectedResponse(let expected, let actual):
            return String(format: "Unexpected PromLight response 0x%02X (expected 0x%02X)", actual, expected)
        case .invalidResponsePayload: return "PromLight returned an invalid response payload"
        }
    }

    private static func errorName(_ detail: UInt8?) -> String {
        switch detail {
        case 1: return "invalid command"
        case 2: return "invalid parameter"
        case 3: return "checksum error"
        case 4: return "device busy"
        case 5: return "value out of range"
        case .some(let value): return "device error \(value)"
        case nil: return "unknown device error"
        }
    }
}

public enum DeviceProtocol {
    public static let readCode: UInt8 = 0x02
    public static let writeCode: UInt8 = 0x03
    public static let lightCode: UInt8 = 0x04

    public static func request(for instruction: DeviceInstruction) throws -> AtomicFrame? {
        switch instruction {
        case .wait:
            return nil
        case .read(let parameter):
            return try AtomicFrame(code: readCode, payload: [address(for: parameter)])
        case .write(let parameter, let value):
            return try AtomicFrame(code: writeCode, payload: [address(for: parameter), try encodedValue(value, for: parameter)])
        case .light(let command):
            var payload = [command.channels.rawValue, actionCode(command.action)]
            if command.only { payload += [0x01, 0xFF] }
            if let count = command.count {
                guard count <= UInt16(UInt8.max) else { throw CommandParseError.outOfRange(String(count)) }
                payload += [0x02, UInt8(count)]
            }
            if let frequency = command.frequencyMilliseconds {
                payload += [0x03, try encodedHundredMilliseconds(Int(frequency))]
            }
            if let fade = command.fadeMilliseconds {
                payload += [0x04, try encodedHundredMilliseconds(Int(fade))]
            }
            return try AtomicFrame(code: lightCode, payload: payload)
        }
    }

    public static func validate(_ response: AtomicFrame, for request: AtomicFrame) throws -> [UInt8] {
        let base = response.code & 0x3F
        guard base == request.code else {
            throw AtomicProtocolError.unexpectedResponse(expected: request.code | 0x80, actual: response.code)
        }
        if response.code & 0x40 != 0 && response.code & 0x80 == 0 {
            throw AtomicProtocolError.deviceError(code: response.code, detail: response.payload.first)
        }
        let expected = request.code | 0x80
        guard response.code == expected else {
            throw AtomicProtocolError.unexpectedResponse(expected: expected, actual: response.code)
        }
        return response.payload
    }

    public static func decodedParameter(_ payload: [UInt8], parameter: PersistentParameter) throws -> Int {
        guard payload.count >= 2, payload[0] == address(for: parameter) else {
            throw AtomicProtocolError.invalidResponsePayload
        }
        switch parameter {
        case .frequency, .fadeTime: return Int(payload[1]) * 100
        case .brightness, .advertisingTimeout: return Int(payload[1])
        }
    }

    private static func address(for parameter: PersistentParameter) -> UInt8 {
        switch parameter {
        case .brightness: return 1
        case .frequency: return 2
        case .fadeTime: return 3
        case .advertisingTimeout: return 4
        }
    }

    private static func actionCode(_ action: LightAction) -> UInt8 {
        switch action {
        case .off: return 0
        case .on: return 1
        case .blink: return 2
        }
    }

    private static func encodedValue(_ value: Int, for parameter: PersistentParameter) throws -> UInt8 {
        switch parameter {
        case .frequency, .fadeTime: return try encodedHundredMilliseconds(value)
        case .brightness, .advertisingTimeout:
            guard (0...Int(UInt8.max)).contains(value) else { throw CommandParseError.outOfRange(String(value)) }
            return UInt8(value)
        }
    }

    private static func encodedHundredMilliseconds(_ milliseconds: Int) throws -> UInt8 {
        guard milliseconds % 100 == 0, (0...(Int(UInt8.max) * 100)).contains(milliseconds) else {
            throw CommandParseError.outOfRange("\(milliseconds)ms")
        }
        return UInt8(milliseconds / 100)
    }
}
