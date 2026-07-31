import XCTest
@testable import PromLightCore

final class AtomicProtocolTests: XCTestCase {
    func testDocumentedGreenOnVector() throws {
        let frame = try DeviceProtocol.request(for: .light(LightCommand(channels: .green, action: .on)))
        XCTAssertEqual(frame?.encoded, [0x5E, 0x5E, 0x04, 0x04, 0x01, 0x01, 0x00])
        XCTAssertEqual(frame?.outputReport.count, 64)
    }

    func testDocumentedAllOffVector() throws {
        let frame = try DeviceProtocol.request(for: .light(LightCommand(channels: .all, action: .off)))
        XCTAssertEqual(frame?.encoded, [0x5E, 0x5E, 0x04, 0x04, 0xFF, 0x00, 0xFF])
    }

    func testDocumentedBlinkOptionsVector() throws {
        let frame = try DeviceProtocol.request(for: .light(LightCommand(
            channels: .red,
            action: .blink,
            only: true,
            count: 3,
            frequencyMilliseconds: 300
        )))
        XCTAssertEqual(frame?.encoded, [0x5E, 0x5E, 0x0A, 0x04, 0x04, 0x02, 0x01, 0xFF, 0x02, 0x03, 0x03, 0x03, 0xF7])
    }

    func testDocumentedParameterVectors() throws {
        XCTAssertEqual(
            try DeviceProtocol.request(for: .write(.brightness, value: 80))?.encoded,
            [0x5E, 0x5E, 0x04, 0x03, 0x01, 0x50, 0x56]
        )
        XCTAssertEqual(
            try DeviceProtocol.request(for: .read(.fadeTime))?.encoded,
            [0x5E, 0x5E, 0x03, 0x02, 0x03, 0x02]
        )
    }

    func testDecodesCapturedReadResponse() throws {
        let report: [UInt8] = [0x02, 0x5E, 0x5E, 0x04, 0x82, 0x02, 0x0A, 0x8E] + Array(repeating: 0, count: 57)
        let response = try AtomicFrame.decode(from: report)
        let request = try XCTUnwrap(DeviceProtocol.request(for: .read(.frequency)))
        let payload = try DeviceProtocol.validate(response, for: request)
        XCTAssertEqual(try DeviceProtocol.decodedParameter(payload, parameter: .frequency), 1_000)
    }

    func testRejectsBadChecksum() {
        XCTAssertThrowsError(try AtomicFrame.decode(from: [0x5E, 0x5E, 0x03, 0x02, 0x03, 0x03]))
    }
}
