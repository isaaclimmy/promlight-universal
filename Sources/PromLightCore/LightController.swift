import Foundation

public struct InstructionResult: Equatable, Sendable {
    public var instruction: DeviceInstruction
    public var value: Int?

    public init(instruction: DeviceInstruction, value: Int? = nil) {
        self.instruction = instruction
        self.value = value
    }
}

public enum LightControllerError: Error, CustomStringConvertible {
    case deviceNotFound(String?)

    public var description: String {
        switch self {
        case .deviceNotFound(.some(let selector)): return "No connected PromLight matches \(selector)"
        case .deviceNotFound(nil): return "No connected PromLight devices were found"
        }
    }
}

public final class LightController: @unchecked Sendable {
    private let transport: any DeviceTransport

    public init(transport: any DeviceTransport = IOKitHIDTransport()) {
        self.transport = transport
    }

    public func devices() throws -> [PromLightDevice] {
        try transport.enumerate()
    }

    @discardableResult
    public func execute(script: String, deviceSelector: String? = nil) throws -> [InstructionResult] {
        let devices = try transport.enumerate()
        guard let device = selectDevice(devices, selector: deviceSelector) else {
            throw LightControllerError.deviceNotFound(deviceSelector)
        }

        return try NorthboundCompiler.compileScript(script).map { instruction in
            let response = try transport.transact(device: device, instruction: instruction)
            if case .read(let parameter) = instruction {
                return InstructionResult(
                    instruction: instruction,
                    value: try DeviceProtocol.decodedParameter(Array(response), parameter: parameter)
                )
            }
            return InstructionResult(instruction: instruction)
        }
    }

    private func selectDevice(_ devices: [PromLightDevice], selector: String?) -> PromLightDevice? {
        guard let selector, !selector.isEmpty else { return devices.first }
        let key = selector.lowercased()
        return devices.first {
            $0.serialNumber.lowercased() == key ||
                $0.serialNumber.lowercased().hasSuffix(key) ||
                String(format: "%llx", $0.registryID).lowercased() == key
        }
    }
}
