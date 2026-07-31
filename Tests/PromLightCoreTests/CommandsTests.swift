import XCTest
@testable import PromLightCore

final class CommandsTests: XCTestCase {
    func testCompilesLightCommand() throws {
        let result = try NorthboundCompiler.compileLine("led yellow blink --only --count 6 --freq 1s --fade 500ms")
        XCTAssertEqual(
            result,
            .light(LightCommand(
                channels: .yellow,
                action: .blink,
                only: true,
                count: 6,
                frequencyMilliseconds: 1_000,
                fadeMilliseconds: 500
            ))
        )
    }

    func testCompilesScriptAndWait() throws {
        let result = try NorthboundCompiler.compileScript("led all blink --count 2; wait 2s; led green on")
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[1], .wait(milliseconds: 2_000))
    }

    func testRejectsOutOfRangeFrequency() {
        XCTAssertThrowsError(try NorthboundCompiler.compileLine("led red blink --freq 50ms"))
    }

    func testLightStateUsesLastLightInstructionInScript() {
        XCTAssertEqual(
            LightStateDescription.infer(
                from: "led yellow blink --only --count 2; wait 1s; led green on --only"
            ),
            "Green"
        )
        XCTAssertEqual(
            LightStateDescription.infer(from: "led red on; wait 1s; read led.brightness"),
            "Red"
        )
    }

    func testLightStateDescribesSingleColorBlinking() {
        XCTAssertEqual(LightStateDescription.infer(from: "led red blink"), "Red blinking")
        XCTAssertEqual(LightStateDescription.infer(from: "led yellow blink"), "Yellow blinking")
        XCTAssertEqual(LightStateDescription.infer(from: "led green blink"), "Green blinking")
    }

    func testLightStateDescribesAllOffAndMultipleChannels() {
        XCTAssertEqual(LightStateDescription.infer(from: "led all off"), "Off")
        XCTAssertEqual(LightStateDescription.infer(from: "led red+green on"), "Red and green on")
        XCTAssertEqual(LightStateDescription.infer(from: "led red+yellow off"), "Red and yellow off")
        XCTAssertEqual(
            LightStateDescription.infer(from: "led red+yellow+green blink"),
            "Red, yellow, and green blinking"
        )
    }

    func testLightStateReturnsNilWithoutAValidLightInstruction() {
        XCTAssertNil(LightStateDescription.infer(from: "wait 1s; read led.brightness"))
        XCTAssertNil(LightStateDescription.infer(from: "not a command"))
    }

    func testExpandsDefaultMacro() {
        let configuration = EventConfiguration()
        XCTAssertEqual(configuration.command(for: "PermissionRequest"), "led yellow blink --only")
        XCTAssertEqual(
            configuration.command(for: "SessionStart"),
            "led all blink --only --count 2 ; wait 2s ; led green on"
        )
    }

    func testProjectRoutingUsesLongestPrefix() {
        let configuration = DeviceConfiguration(
            routes: ["/tmp/project": "A", "/tmp/project/sub": "B"],
            defaultDevice: "C"
        )
        XCTAssertEqual(configuration.route(cwd: "/tmp/project/sub/file", agent: nil), "B")
        XCTAssertEqual(configuration.route(cwd: "/outside", agent: nil), "C")
    }

    func testRoutingResolvesAlias() {
        let configuration = DeviceConfiguration(
            aliases: ["Desk": "9C7F643B39CA"],
            agents: ["codex": "Desk"]
        )
        XCTAssertEqual(configuration.resolvedRoute(cwd: nil, agent: "codex"), "9C7F643B39CA")
    }
}
