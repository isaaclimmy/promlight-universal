import CoreFoundation
import Foundation
import IOKit
import IOKit.hid

public struct PromLightDevice: Hashable, Sendable {
    public var registryID: UInt64
    public var vendorID: Int
    public var productID: Int
    public var product: String
    public var serialNumber: String
    public var versionNumber: Int
    public var accessoryIdentifier: String

    public init(
        registryID: UInt64,
        vendorID: Int,
        productID: Int,
        product: String,
        serialNumber: String,
        versionNumber: Int,
        accessoryIdentifier: String = ""
    ) {
        self.registryID = registryID
        self.vendorID = vendorID
        self.productID = productID
        self.product = product
        self.serialNumber = serialNumber
        self.versionNumber = versionNumber
        self.accessoryIdentifier = accessoryIdentifier
    }
}

public protocol DeviceTransport: Sendable {
    func enumerate() throws -> [PromLightDevice]
    func transact(device: PromLightDevice, instruction: DeviceInstruction) throws -> Data
}

public enum HIDTransportError: Error, CustomStringConvertible {
    case managerCreationFailed
    case deviceNotFound
    case openFailed(IOReturn)
    case setReportFailed(IOReturn)
    case inputReportFailed(IOReturn)
    case responseTimedOut

    public var description: String {
        switch self {
        case .managerCreationFailed: return "Unable to create the macOS HID manager"
        case .deviceNotFound: return "PromLight is not connected"
        case .openFailed(let code): return "Unable to open PromLight (IOReturn \(code))"
        case .setReportFailed(let code): return "Unable to send a PromLight report (IOReturn \(code))"
        case .inputReportFailed(let code): return "Unable to receive a PromLight report (IOReturn \(code))"
        case .responseTimedOut: return "PromLight did not respond before the timeout"
        }
    }
}

public final class IOKitHIDTransport: DeviceTransport, @unchecked Sendable {
    public static let vendorID = 0x07D7
    public static let productID = 0x6B01
    public static let usagePage = 0xFF00
    public static let usage = 0x01
    static let matchingCriteria = [
        kIOHIDVendorIDKey: vendorID,
        kIOHIDProductIDKey: productID,
        kIOHIDDeviceUsagePageKey: usagePage,
        kIOHIDDeviceUsageKey: usage,
    ]

    private let lock = NSLock()
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 2) {
        self.timeout = timeout
    }

    public func enumerate() throws -> [PromLightDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match PromLight before opening the manager. Opening an unfiltered
        // manager asks macOS for access to every HID collection, including
        // keyboards, and makes a background LaunchAgent require the broad
        // Input Monitoring privacy permission. PromLight is a vendor-defined
        // BLE HID collection and does not need that access.
        IOHIDManagerSetDeviceMatching(manager, Self.deviceMatching)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw HIDTransportError.openFailed(result) }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.compactMap(Self.describe).sorted { $0.serialNumber < $1.serialNumber }
    }

    public func transact(device: PromLightDevice, instruction: DeviceInstruction) throws -> Data {
        if case .wait(let milliseconds) = instruction {
            Thread.sleep(forTimeInterval: Double(milliseconds) / 1_000)
            return Data()
        }
        guard let request = try DeviceProtocol.request(for: instruction) else { return Data() }

        lock.lock()
        defer { lock.unlock() }

        let (manager, hidDevice) = try openDevice(registryID: device.registryID)
        defer {
            IOHIDDeviceClose(hidDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        let state = InputState(expectedBaseCode: request.code)
        var inputBuffer = [UInt8](repeating: 0, count: 65)
        guard let runLoop = CFRunLoopGetCurrent() else { throw HIDTransportError.responseTimedOut }
        IOHIDDeviceScheduleWithRunLoop(hidDevice, runLoop, CFRunLoopMode.defaultMode.rawValue)
        defer { IOHIDDeviceUnscheduleFromRunLoop(hidDevice, runLoop, CFRunLoopMode.defaultMode.rawValue) }

        try inputBuffer.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { throw AtomicProtocolError.truncated }
            IOHIDDeviceRegisterInputReportCallback(
                hidDevice,
                baseAddress,
                buffer.count,
                Self.inputCallback,
                Unmanaged.passUnretained(state).toOpaque()
            )

            // Drain reports that predate this request. The protocol has no
            // transaction ID, so accepting a stale acknowledgement could
            // shift every subsequent command/response pair.
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
            state.response = nil
            state.error = nil
            state.accepting = true

            let output = request.outputReport
            let setResult = output.withUnsafeBytes { bytes -> IOReturn in
                guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else { return kIOReturnBadArgument }
                return IOHIDDeviceSetReport(
                    hidDevice,
                    kIOHIDReportTypeOutput,
                    AtomicFrame.reportID,
                    baseAddress,
                    output.count
                )
            }
            guard setResult == kIOReturnSuccess else { throw HIDTransportError.setReportFailed(setResult) }

            let deadline = Date().addingTimeInterval(timeout)
            while state.response == nil && state.error == nil && Date() < deadline {
                CFRunLoopRunInMode(.defaultMode, min(0.05, deadline.timeIntervalSinceNow), true)
            }
        }

        if let result = state.error { throw HIDTransportError.inputReportFailed(result) }
        guard let response = state.response else { throw HIDTransportError.responseTimedOut }
        let payload = try DeviceProtocol.validate(response, for: request)
        return Data(payload)
    }

    private func openDevice(registryID: UInt64) throws -> (IOHIDManager, IOHIDDevice) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, Self.deviceMatching)
        let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard managerResult == kIOReturnSuccess else { throw HIDTransportError.openFailed(managerResult) }
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = set.first(where: { candidate in
                  var candidateID: UInt64 = 0
                  IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(candidate), &candidateID)
                  return candidateID == registryID
              }) else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw HIDTransportError.deviceNotFound
        }
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw HIDTransportError.openFailed(openResult)
        }
        return (manager, device)
    }

    private static let inputCallback: IOHIDReportCallback = { context, result, _, _, reportID, report, reportLength in
        guard let context else { return }
        let state = Unmanaged<InputState>.fromOpaque(context).takeUnretainedValue()
        guard result == kIOReturnSuccess else {
            state.error = result
            return
        }
        guard state.accepting else { return }
        var bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
        if bytes.first != UInt8(reportID) { bytes.insert(UInt8(reportID), at: 0) }
        guard let frame = try? AtomicFrame.decode(from: bytes), frame.code & 0x3F == state.expectedBaseCode else { return }
        state.response = frame
    }

    private final class InputState {
        let expectedBaseCode: UInt8
        var response: AtomicFrame?
        var error: IOReturn?
        var accepting = false

        init(expectedBaseCode: UInt8) {
            self.expectedBaseCode = expectedBaseCode
        }
    }

    private static func describe(_ device: IOHIDDevice) -> PromLightDevice? {
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
        return PromLightDevice(
            registryID: registryID,
            vendorID: integerProperty(device, kIOHIDVendorIDKey),
            productID: integerProperty(device, kIOHIDProductIDKey),
            product: stringProperty(device, kIOHIDProductKey),
            serialNumber: stringProperty(device, kIOHIDSerialNumberKey),
            versionNumber: integerProperty(device, kIOHIDVersionNumberKey),
            accessoryIdentifier: stringProperty(device, "PhysicalDeviceUniqueID")
        )
    }

    private static var deviceMatching: CFDictionary {
        matchingCriteria as CFDictionary
    }

    private static func property(_ device: IOHIDDevice, _ key: String) -> CFTypeRef? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }

    private static func integerProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (property(device, key) as? NSNumber)?.intValue ?? 0
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String {
        property(device, key) as? String ?? ""
    }
}
