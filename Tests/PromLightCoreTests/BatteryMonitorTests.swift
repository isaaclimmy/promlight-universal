import Foundation
import XCTest
@testable import PromLightCore

private final class BatteryReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class BatteryMonitorTests: XCTestCase {
    func testParsesMatchingAccessoryPowerSource() throws {
        let readings = PromLightBatteryReader.parsePowerSources([
            [
                "Name": "PromLight",
                "Vendor ID": NSNumber(value: IOKitHIDTransport.vendorID),
                "Product ID": NSNumber(value: IOKitHIDTransport.productID),
                "Transport Type": "Bluetooth LE",
                "Current Capacity": NSNumber(value: 49),
                "Max Capacity": NSNumber(value: 50),
                "Accessory Identifier": "D7FB32E2-5C0E-BACE-2188-678E13DB994D",
            ],
        ])

        XCTAssertEqual(readings, [
            PromLightBatteryStatus(
                level: 98,
                accessoryIdentifier: "D7FB32E2-5C0E-BACE-2188-678E13DB994D"
            ),
        ])
    }

    func testRejectsOtherAccessoriesAndInvalidCapacity() {
        let base: [String: Any] = [
            "Vendor ID": NSNumber(value: IOKitHIDTransport.vendorID),
            "Product ID": NSNumber(value: IOKitHIDTransport.productID),
            "Transport Type": "Bluetooth LE",
            "Current Capacity": NSNumber(value: 50),
            "Max Capacity": NSNumber(value: 100),
        ]
        var wrongVendor = base
        wrongVendor["Vendor ID"] = NSNumber(value: 1)
        var wrongProduct = base
        wrongProduct["Product ID"] = NSNumber(value: 1)
        var wrongTransport = base
        wrongTransport["Transport Type"] = "USB"
        var zeroMaximum = base
        zeroMaximum["Max Capacity"] = NSNumber(value: 0)

        XCTAssertTrue(PromLightBatteryReader.parsePowerSources([
            wrongVendor, wrongProduct, wrongTransport, zeroMaximum,
        ]).isEmpty)
    }

    func testStructuredCapacityIsRoundedAndRejectsOutOfRangeValues() {
        func source(current: Int, maximum: Int) -> [String: Any] {
            [
                "Vendor ID": NSNumber(value: IOKitHIDTransport.vendorID),
                "Product ID": NSNumber(value: IOKitHIDTransport.productID),
                "Transport Type": "Bluetooth LE",
                "Current Capacity": NSNumber(value: current),
                "Max Capacity": NSNumber(value: maximum),
            ]
        }

        XCTAssertEqual(
            PromLightBatteryReader.parsePowerSources([
                source(current: 2, maximum: 3),
                source(current: 120, maximum: 100),
                source(current: -1, maximum: 100),
            ]).map(\.level),
            [67]
        )
    }

    func testParsesOnlyPromLightFromPMSetOutput() {
        let output = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=22347875)\t100%; charged; 0:00 remaining present: true
         -AirPods (id=123)\t74%;
         -PromLight (id=39457689)\t98%;
        """

        XCTAssertEqual(
            PromLightBatteryReader.parsePMSetOutput(output),
            [PromLightBatteryStatus(level: 98)]
        )
        XCTAssertTrue(PromLightBatteryReader.parsePMSetOutput("-PromLight (id=1) 101%;").isEmpty)
    }

    func testMatchesDeviceByAccessoryIdentifier() {
        let device = PromLightDevice(
            registryID: 1,
            vendorID: IOKitHIDTransport.vendorID,
            productID: IOKitHIDTransport.productID,
            product: "PromLight",
            serialNumber: "TEST",
            versionNumber: 1,
            accessoryIdentifier: "SECOND"
        )
        let readings = [
            PromLightBatteryStatus(level: 20, accessoryIdentifier: "FIRST"),
            PromLightBatteryStatus(level: 80, accessoryIdentifier: "SECOND"),
        ]

        XCTAssertEqual(PromLightBatteryReader.battery(
            for: device,
            in: readings,
            allowAnonymousFallback: false
        )?.level, 80)
    }

    func testDoesNotCrossAssignAnotherIdentifiedAccessory() {
        let device = makeDevice(accessoryIdentifier: "EXPECTED")
        let readings = [PromLightBatteryStatus(level: 80, accessoryIdentifier: "OTHER")]

        XCTAssertNil(PromLightBatteryReader.battery(
            for: device,
            in: readings,
            allowAnonymousFallback: true
        ))
    }

    func testAnonymousFallbackRequiresOneDeviceAndOneReading() {
        let device = makeDevice(accessoryIdentifier: "EXPECTED")
        let single = [PromLightBatteryStatus(level: 75)]
        let multiple = [PromLightBatteryStatus(level: 75), PromLightBatteryStatus(level: 60)]

        XCTAssertEqual(PromLightBatteryReader.battery(
            for: device,
            in: single,
            allowAnonymousFallback: true
        )?.level, 75)
        XCTAssertNil(PromLightBatteryReader.battery(
            for: device,
            in: single,
            allowAnonymousFallback: false
        ))
        XCTAssertNil(PromLightBatteryReader.battery(
            for: device,
            in: multiple,
            allowAnonymousFallback: true
        ))
    }

    func testMonitorCachesReadsUntilRefreshIntervalExpires() {
        let counter = BatteryReadCounter()
        let monitor = PromLightBatteryMonitor(refreshInterval: 60) {
            counter.increment()
            return [PromLightBatteryStatus(level: counter.count)]
        }
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(monitor.readings(now: start).first?.level, 1)
        XCTAssertEqual(monitor.readings(now: start.addingTimeInterval(59)).first?.level, 1)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(monitor.readings(now: start.addingTimeInterval(60)).first?.level, 2)
        XCTAssertEqual(counter.count, 2)

        monitor.invalidate()
        XCTAssertEqual(monitor.readings(now: start.addingTimeInterval(61)).first?.level, 3)
    }

    func testConnectedDeviceChangesInvalidateCachedReading() {
        let counter = BatteryReadCounter()
        let monitor = PromLightBatteryMonitor(refreshInterval: 60) {
            counter.increment()
            return [PromLightBatteryStatus(level: counter.count)]
        }
        let firstDevice = makeDevice(accessoryIdentifier: "FIRST")
        let secondDevice = makeDevice(accessoryIdentifier: "SECOND")
        let start = Date(timeIntervalSince1970: 2_000)

        XCTAssertTrue(monitor.updateConnectedDevices([firstDevice]))
        XCTAssertEqual(monitor.readings(now: start).first?.level, 1)
        XCTAssertFalse(monitor.updateConnectedDevices([firstDevice]))
        XCTAssertEqual(monitor.readings(now: start.addingTimeInterval(30)).first?.level, 1)

        XCTAssertTrue(monitor.updateConnectedDevices([]))
        XCTAssertTrue(monitor.updateConnectedDevices([secondDevice]))
        XCTAssertEqual(monitor.readings(now: start.addingTimeInterval(31)).first?.level, 2)
    }

    private func makeDevice(accessoryIdentifier: String) -> PromLightDevice {
        PromLightDevice(
            registryID: 1,
            vendorID: IOKitHIDTransport.vendorID,
            productID: IOKitHIDTransport.productID,
            product: "PromLight",
            serialNumber: "TEST",
            versionNumber: 1,
            accessoryIdentifier: accessoryIdentifier
        )
    }
}
