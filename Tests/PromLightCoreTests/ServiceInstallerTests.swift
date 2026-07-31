import Foundation
import XCTest
@testable import PromLightCore

final class ServiceInstallerTests: XCTestCase {
    func testManifestUsesNativeHeadlessExecutable() throws {
        let url = URL(fileURLWithPath: "/Applications/PromLight Universal.app/Contents/MacOS/PromLight")
        let data = try ServiceInstaller.manifest(executableURL: url)
        let root = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(root["Label"] as? String, "com.promlight.universal")
        XCTAssertEqual(root["ProgramArguments"] as? [String], [url.path, "--headless"])
        XCTAssertEqual(root["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(root["KeepAlive"] as? Bool, true)
    }
}
