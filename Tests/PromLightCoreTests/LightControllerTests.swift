import Foundation
import IOKit.hid
import XCTest
@testable import PromLightCore

final class LightControllerTests: XCTestCase {
    func testNativeEnumerationIsScopedToPromLightOnly() {
        XCTAssertEqual(IOKitHIDTransport.matchingCriteria.count, 4)
        XCTAssertEqual(IOKitHIDTransport.matchingCriteria[kIOHIDVendorIDKey], 0x07D7)
        XCTAssertEqual(IOKitHIDTransport.matchingCriteria[kIOHIDProductIDKey], 0x6B01)
        XCTAssertEqual(IOKitHIDTransport.matchingCriteria[kIOHIDDeviceUsagePageKey], 0xFF00)
        XCTAssertEqual(IOKitHIDTransport.matchingCriteria[kIOHIDDeviceUsageKey], 0x01)
    }

    func testExecutesScriptAgainstSelectedDevice() throws {
        let transport = MockTransport()
        let controller = LightController(transport: transport)
        let results = try controller.execute(script: "led green on; read led.brightness", deviceSelector: "39CA")
        XCTAssertEqual(transport.instructions.count, 2)
        XCTAssertEqual(results.last?.value, 15)
    }
}

private final class MockTransport: DeviceTransport, @unchecked Sendable {
    var instructions: [DeviceInstruction] = []

    func enumerate() throws -> [PromLightDevice] {
        [PromLightDevice(registryID: 1, vendorID: 0x07D7, productID: 0x6B01, product: "PromLight", serialNumber: "9C7F643B39CA", versionNumber: 0x13)]
    }

    func transact(device: PromLightDevice, instruction: DeviceInstruction) throws -> Data {
        instructions.append(instruction)
        if case .read(.brightness) = instruction { return Data([1, 15]) }
        return Data()
    }
}
