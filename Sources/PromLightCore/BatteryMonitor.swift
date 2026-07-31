import Darwin
import Foundation

public struct PromLightBatteryStatus: Codable, Equatable, Sendable {
    public var level: Int
    public var accessoryIdentifier: String?

    public init(level: Int, accessoryIdentifier: String? = nil) {
        self.level = min(100, max(0, level))
        self.accessoryIdentifier = accessoryIdentifier
    }
}

public enum PromLightBatteryReader {
    private static let accessoryPowerSourceType: UInt32 = 4
    private static let frameworkPath = "/System/Library/Frameworks/IOKit.framework/IOKit"
    private static let copyFunctionName = "IOPSCopyPowerSourcesByType"

    private typealias CopyPowerSourcesByTypeFunction =
        @convention(c) (UInt32) -> Unmanaged<CFArray>?

    public static func readAll() -> [PromLightBatteryStatus] {
        let structured = parsePowerSources(copyAccessoryPowerSources())
        return structured.isEmpty ? readPMSetFallback() : structured
    }

    public static func battery(
        for device: PromLightDevice,
        in readings: [PromLightBatteryStatus],
        allowAnonymousFallback: Bool
    ) -> PromLightBatteryStatus? {
        if !device.accessoryIdentifier.isEmpty,
           let exact = readings.first(where: { $0.accessoryIdentifier == device.accessoryIdentifier }) {
            return exact
        }
        // A structured accessory source with a different identifier belongs to
        // another paired light. Never cross-assign it. The `pmset` fallback has
        // no identifiers, so callers may use it only when exactly one hardware
        // device is connected and exactly one reading is available.
        if !device.accessoryIdentifier.isEmpty,
           readings.contains(where: { !($0.accessoryIdentifier ?? "").isEmpty }) {
            return nil
        }
        guard allowAnonymousFallback, readings.count == 1 else { return nil }
        return readings.first
    }

    static func parsePowerSources(_ sources: [[String: Any]]) -> [PromLightBatteryStatus] {
        sources.compactMap { source in
            guard integer(source["Vendor ID"]) == IOKitHIDTransport.vendorID,
                  integer(source["Product ID"]) == IOKitHIDTransport.productID,
                  (source["Transport Type"] as? String) == "Bluetooth LE",
                  let current = integer(source["Current Capacity"]),
                  let maximum = integer(source["Max Capacity"]),
                  maximum > 0,
                  (0...maximum).contains(current) else {
                return nil
            }
            let percentage = Int((Double(current) * 100 / Double(maximum)).rounded())
            return PromLightBatteryStatus(
                level: percentage,
                accessoryIdentifier: source["Accessory Identifier"] as? String
            )
        }
    }

    static func parsePMSetOutput(_ output: String) -> [PromLightBatteryStatus] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("-PromLight "),
                  let percentIndex = line.firstIndex(of: "%") else {
                return nil
            }
            let prefix = line[..<percentIndex]
            guard let rawLevel = prefix.split(whereSeparator: \.isWhitespace).last,
                  let level = Int(rawLevel), (0...100).contains(level) else {
                return nil
            }
            return PromLightBatteryStatus(level: level)
        }
    }

    private static func copyAccessoryPowerSources() -> [[String: Any]] {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else { return [] }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, copyFunctionName) else { return [] }
        let copySources = unsafeBitCast(symbol, to: CopyPowerSourcesByTypeFunction.self)
        // The function follows Core Foundation's Copy rule. Consume the +1
        // object exactly once; dynamic lookup keeps older macOS releases safe
        // if accessory power-source support is unavailable.
        return copySources(accessoryPowerSourceType)?.takeRetainedValue()
            as? [[String: Any]] ?? []
    }

    private static func readPMSetFallback() -> [PromLightBatteryStatus] {
        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "accps"]
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard !process.isRunning else {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(0.25)
                while process.isRunning && Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                return []
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
            return parsePMSetOutput(String(decoding: data, as: UTF8.self))
        } catch {
            return []
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}

public final class PromLightBatteryMonitor: @unchecked Sendable {
    public typealias Reader = @Sendable () -> [PromLightBatteryStatus]

    private let lock = NSLock()
    private let refreshInterval: TimeInterval
    private let reader: Reader
    private var lastRefresh: Date?
    private var cachedReadings: [PromLightBatteryStatus] = []
    private var connectedDeviceIdentities: Set<String>?

    public init(
        refreshInterval: TimeInterval = 60,
        reader: @escaping Reader = { PromLightBatteryReader.readAll() }
    ) {
        self.refreshInterval = max(0, refreshInterval)
        self.reader = reader
    }

    public func battery(
        for device: PromLightDevice,
        allowAnonymousFallback: Bool,
        now: Date = Date()
    ) -> PromLightBatteryStatus? {
        PromLightBatteryReader.battery(
            for: device,
            in: readings(now: now),
            allowAnonymousFallback: allowAnonymousFallback
        )
    }

    public func readings(now: Date = Date(), forceRefresh: Bool = false) -> [PromLightBatteryStatus] {
        lock.lock()
        if !forceRefresh,
           let lastRefresh,
           now.timeIntervalSince(lastRefresh) < refreshInterval {
            let cached = cachedReadings
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Do not hold the cache lock while consulting macOS. The compatibility
        // fallback launches `pmset`, and a slow subprocess must not block
        // invalidation or other callers from reading an already-valid value.
        let freshReadings = reader()

        lock.lock()
        defer { lock.unlock() }
        if !forceRefresh,
           let lastRefresh,
           now.timeIntervalSince(lastRefresh) < refreshInterval {
            return cachedReadings
        }
        cachedReadings = freshReadings
        lastRefresh = now
        return cachedReadings
    }

    /// Clears cached battery data whenever the connected hardware set changes.
    /// This makes a disconnect/reconnect refresh immediately instead of showing
    /// a reading from as much as one cache interval ago.
    @discardableResult
    public func updateConnectedDevices(_ devices: [PromLightDevice]) -> Bool {
        let identities = Set(devices.map { device in
            if !device.accessoryIdentifier.isEmpty {
                return "accessory:\(device.accessoryIdentifier)"
            }
            return "registry:\(device.registryID)"
        })

        lock.lock()
        defer { lock.unlock() }
        guard connectedDeviceIdentities != identities else { return false }
        connectedDeviceIdentities = identities
        lastRefresh = nil
        cachedReadings = []
        return true
    }

    public func invalidate() {
        lock.lock()
        lastRefresh = nil
        cachedReadings = []
        lock.unlock()
    }
}
