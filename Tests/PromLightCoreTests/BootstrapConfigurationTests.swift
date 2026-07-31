import Foundation
import XCTest
@testable import PromLightCore

final class BootstrapConfigurationTests: XCTestCase {
    func testApplicationConfigurationRoundTrip() throws {
        let value = ApplicationConfiguration(hookPort: 47_801, webPort: 7_801, openBrowser: false)
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(ApplicationConfiguration.self, from: data), value)
    }

    func testMissingConfigUsesEnglishDefaults() throws {
        let value = try ApplicationConfiguration.load(from: URL(fileURLWithPath: "/tmp/no-promlight-config.json"))
        XCTAssertEqual(value.hookPort, 47_800)
        XCTAssertEqual(value.webPort, 7_800)
        XCTAssertTrue(value.openBrowser)
    }
}
