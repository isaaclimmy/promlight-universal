import Foundation
import XCTest
@testable import PromLightCore

private final class WebConsoleCapture<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func store(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

final class WebConsoleTests: XCTestCase {
    func testHTTPParserWaitsForCompleteBodyAndNormalizesHeaders() throws {
        let body = Data(#"{"command":"led green on --only"}"#.utf8)
        let head = "POST /api/command?source=test HTTP/1.1\r\n" +
            "Host: 127.0.0.1:7800\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "\r\n"
        let requestData = Data(head.utf8) + body

        XCTAssertNil(try WebConsoleHTTPRequestParser.parse(Data(requestData.dropLast())))

        let request = try XCTUnwrap(WebConsoleHTTPRequestParser.parse(requestData))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/api/command?source=test")
        XCTAssertEqual(request.headers["content-type"], "application/json; charset=utf-8")
        XCTAssertEqual(request.body, body)
    }

    func testHTTPParserRejectsOversizedBodyBeforeReceivingIt() {
        let request = Data((
            "POST /api/event HTTP/1.1\r\n" +
            "Content-Length: \(WebConsoleHTTPRequestParser.maximumBodyBytes + 1)\r\n" +
            "\r\n"
        ).utf8)

        XCTAssertThrowsError(try WebConsoleHTTPRequestParser.parse(request)) { error in
            XCTAssertEqual(error as? WebConsoleHTTPParseError, .bodyTooLarge)
        }
    }

    func testRenderedConsoleIsEnglishAccessibleAndSelfContained() throws {
        let router = makeRouter()
        let response = router.response(for: WebConsoleHTTPRequest(
            method: "GET",
            target: "/",
            version: "HTTP/1.1",
            headers: [:],
            body: Data()
        ))
        let html = try XCTUnwrap(String(data: response.body, encoding: .utf8))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(html.contains(#"<html lang="en">"#))
        XCTAssertTrue(html.contains("Quick light controls"))
        XCTAssertTrue(html.contains("AI agent setup"))
        XCTAssertTrue(html.contains("Event log"))
        XCTAssertTrue(html.contains("Battery"))
        XCTAssertTrue(html.contains(#"id="battery-level""#))
        XCTAssertTrue(html.contains("'/Applications/PromLight.app/Contents/MacOS/PromLight' setup codex"))
        XCTAssertTrue(html.contains(#"class="skip-link""#))
        XCTAssertTrue(html.contains(#"label for="command-input""#))
        XCTAssertTrue(html.contains(#"aria-live="polite""#))
        XCTAssertTrue(html.contains("prefers-reduced-motion"))
        XCTAssertTrue(html.contains("/api/status"))
        XCTAssertFalse(html.contains(#"<script src="#))
        XCTAssertFalse(html.contains(#"<link rel="stylesheet"#))
        XCTAssertFalse(containsCJKText(html))
    }

    func testCommandRouteDecodesJSONAndCallsHandler() throws {
        let capture = WebConsoleCapture<String>()
        let router = makeRouter(commandHandler: { command in
            capture.store(command)
            return WebConsoleActionResult(message: "Command completed.")
        })
        let body = Data(#"{"command":"  led yellow blink --only  "}"#.utf8)
        let response = router.response(for: WebConsoleHTTPRequest(
            method: "POST",
            target: "/api/command",
            version: "HTTP/1.1",
            headers: ["content-type": "application/json"],
            body: body
        ))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(capture.value, "led yellow blink --only")
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains(#""accepted":true"#))
    }

    func testEventRoutePreservesUnknownJSONAndCommonFields() {
        let capture = WebConsoleCapture<WebConsoleEvent>()
        let router = makeRouter(eventHandler: { event in
            capture.store(event)
            return WebConsoleActionResult(message: "Event accepted.")
        })
        let body = Data(#"{"hook_event_name":"PermissionRequest","agent":"codex","tool":{"name":"shell"}}"#.utf8)
        let response = router.response(for: WebConsoleHTTPRequest(
            method: "POST",
            target: "/api/event",
            version: "HTTP/1.1",
            headers: ["content-type": "application/json; charset=utf-8"],
            body: body
        ))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(capture.value?.name, "PermissionRequest")
        XCTAssertEqual(capture.value?.agent, "codex")
        XCTAssertEqual(capture.value?.payload["tool"], .object(["name": .string("shell")]))
    }

    func testServerAddressCannotBeConfiguredAwayFromLoopback() {
        XCTAssertEqual(WebConsoleServer.host, "127.0.0.1")
        XCTAssertEqual(WebConsoleServer.port, 7_800)
        XCTAssertEqual(WebConsoleServer.url.absoluteString, "http://127.0.0.1:7800/")
    }

    func testStatusRouteIncludesBatteryLevel() {
        let response = makeRouter().response(for: WebConsoleHTTPRequest(
            method: "GET", target: "/api/status", version: "HTTP/1.1",
            headers: [:], body: Data()
        ))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains(#""batteryLevel":82"#))
    }

    func testHostValidatorRejectsDNSRebindingHost() {
        let local = WebConsoleHTTPRequest(
            method: "GET", target: "/", version: "HTTP/1.1",
            headers: ["host": "127.0.0.1:7800"], body: Data()
        )
        var rebound = local
        rebound.headers["host"] = "attacker.example:7800"
        XCTAssertTrue(WebConsoleHostValidator.allows(local, port: 7_800))
        XCTAssertFalse(WebConsoleHostValidator.allows(rebound, port: 7_800))
    }

    private func makeRouter(
        commandHandler: @escaping WebConsoleCommandHandler = { _ in
            WebConsoleActionResult(message: "Command accepted.")
        },
        eventHandler: @escaping WebConsoleEventHandler = { _ in
            WebConsoleActionResult(message: "Event accepted.")
        }
    ) -> WebConsoleHTTPRouter {
        WebConsoleHTTPRouter(
            statusProvider: {
                WebConsoleStatus(
                    connected: true,
                    deviceName: "PromLight",
                    serialNumber: "TEST-1",
                    batteryLevel: 82,
                    lightState: "Green",
                    activeAgent: "Codex"
                )
            },
            commandHandler: commandHandler,
            eventHandler: eventHandler
        )
    }

    private func containsCJKText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3400...0x4DBF).contains(value) ||
                (0x4E00...0x9FFF).contains(value) ||
                (0xF900...0xFAFF).contains(value)
        }
    }
}
