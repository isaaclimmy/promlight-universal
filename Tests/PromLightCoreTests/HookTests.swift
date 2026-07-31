import Foundation
import XCTest
@testable import PromLightCore

final class HookTests: XCTestCase {
    func testBuildsCodexMessage() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": "session-1",
            "cwd": "/tmp/project",
            "tool_name": "Bash",
        ])
        let message = try XCTUnwrap(HookClient.buildMessage(event: nil, agent: "codex", input: payload, eventsURL: URL(fileURLWithPath: "/tmp/does-not-exist-events.json")))
        XCTAssertEqual(message.cmd, "led yellow blink --only")
        XCTAssertEqual(message.session, "session-1")
        XCTAssertEqual(message.cwd, "/tmp/project")
        XCTAssertTrue(message.message.contains("tool_name=Bash"))
    }

    func testCursorAndAntigravityGateDecisions() {
        XCTAssertEqual(HookClient.gateDecision(agent: "cursor", event: "beforeSubmitPrompt")?["continue"] as? Bool, true)
        XCTAssertEqual(HookClient.gateDecision(agent: "cursor", event: "beforeShellExecution")?["continue"] as? Bool, true)
        XCTAssertEqual(HookClient.gateDecision(agent: "cursor", event: "beforeMCPExecution")?["continue"] as? Bool, true)
        XCTAssertNil(HookClient.gateDecision(agent: "cursor", event: "beforeShellExecution")?["permission"])
        XCTAssertEqual(HookClient.gateDecision(agent: "antigravity", event: "Stop")?["decision"] as? String, "allow")
        XCTAssertEqual(HookClient.gateDecision(agent: "antigravity", event: "PostToolUse")?.count, 0)
    }

    func testAntigravityUsesCurrentPassiveHookSchema() throws {
        let root = HookInstaller.template(
            agent: .antigravity,
            executableURL: URL(fileURLWithPath: "/Applications/PromLight.app/Contents/MacOS/PromLight")
        )
        let section = try XCTUnwrap(root["promlight"] as? [String: Any])
        XCTAssertEqual(section["enabled"] as? Bool, true)
        XCTAssertNil(section["SessionStart"])
        XCTAssertNil(section["UserPromptSubmit"])
        XCTAssertNil(section["PreToolUse"])

        let postTool = try XCTUnwrap((section["PostToolUse"] as? [[String: Any]])?.first)
        XCTAssertEqual(postTool["matcher"] as? String, "*")
        XCTAssertNotNil(postTool["hooks"] as? [[String: Any]])

        for event in ["PreInvocation", "PostInvocation", "Stop"] {
            let handler = try XCTUnwrap((section[event] as? [[String: Any]])?.first)
            XCTAssertNotNil(handler["command"] as? String)
            XCTAssertNil(handler["hooks"])
        }
    }

    func testAntigravityInstallerReplacesOnlyItsNamedSection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("promlight-antigravity-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(".agents/hooks.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "other-hook": ["enabled": true, "Stop": [["command": "/usr/local/bin/keep-me"]]],
            "promlight": ["SessionStart": [["hooks": [["command": "python /old/PromLight/agent_hook.py"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: destination)

        for _ in 0..<2 {
            _ = try HookInstaller.install(
                agent: .antigravity,
                scope: .project(root),
                executableURL: URL(fileURLWithPath: "/Applications/PromLight.app/Contents/MacOS/PromLight")
            )
        }

        let output = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(output.contains("/usr/local/bin/keep-me"))
        XCTAssertTrue(output.contains("hook --agent antigravity PreInvocation"))
        XCTAssertFalse(output.contains("agent_hook.py"))
        XCTAssertEqual(output.components(separatedBy: "hook --agent antigravity PreInvocation").count - 1, 1)
    }

    func testAntigravityMessageUsesConversationAndReleasesOnlyWhenIdle() throws {
        let active = try JSONSerialization.data(withJSONObject: [
            "conversationId": "conversation-1",
            "fullyIdle": false,
            "terminationReason": "background_work",
        ])
        let activeMessage = try XCTUnwrap(HookClient.buildMessage(
            event: "Stop", agent: "antigravity", input: active,
            eventsURL: URL(fileURLWithPath: "/tmp/does-not-exist-events.json")
        ))
        XCTAssertEqual(activeMessage.session, "conversation-1")
        XCTAssertFalse(activeMessage.releaseSession)

        let idle = try JSONSerialization.data(withJSONObject: [
            "conversationId": "conversation-1",
            "fullyIdle": true,
        ])
        let idleMessage = try XCTUnwrap(HookClient.buildMessage(
            event: "Stop", agent: "antigravity", input: idle,
            eventsURL: URL(fileURLWithPath: "/tmp/does-not-exist-events.json")
        ))
        XCTAssertTrue(idleMessage.releaseSession)
    }

    func testUnavailableDaemonFailsQuickly() {
        let message = HookMessage(
            cmd: "led green on", message: "test", session: nil, cwd: nil,
            agent: "codex", releaseSession: false, notice: ""
        )
        let started = Date()
        XCTAssertFalse(HookClient.send(message, port: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testTemplatesUseNativeBinaryWithoutPython() throws {
        let template = HookInstaller.template(agent: .codex, executableURL: URL(fileURLWithPath: "/Applications/PromLight.app/Contents/MacOS/PromLight"))
        let text = String(data: try JSONSerialization.data(withJSONObject: template), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("PromLight.app"))
        XCTAssertTrue(text.contains("hook --agent codex"))
        XCTAssertFalse(text.lowercased().contains("python"))
    }

    func testInstallerPreservesOtherHooksAndReplacesLegacyPromLight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("promlight-hook-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "custom": "keep-me",
            "hooks": [
                "PreToolUse": [
                    ["hooks": [
                        ["type": "command", "command": "python /old/PromLight/agent_hook.py --agent codex PreToolUse"],
                        ["type": "command", "command": "/usr/local/bin/mixed-sibling-hook"],
                    ]],
                    ["hooks": [["type": "command", "command": "/usr/local/bin/my-hook"]]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: destination)

        _ = try HookInstaller.install(
            agent: .codex,
            scope: .project(root),
            executableURL: URL(fileURLWithPath: "/Applications/PromLight.app/Contents/MacOS/PromLight")
        )
        _ = try HookInstaller.install(
            agent: .codex,
            scope: .project(root),
            executableURL: URL(fileURLWithPath: "/Applications/PromLight.app/Contents/MacOS/PromLight")
        )
        let output = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(output.contains("keep-me"))
        XCTAssertTrue(output.contains("/usr/local/bin/my-hook"))
        XCTAssertTrue(output.contains("/usr/local/bin/mixed-sibling-hook"))
        XCTAssertTrue(output.contains("hook --agent codex PreToolUse"))
        XCTAssertFalse(output.contains("agent_hook.py"))
        XCTAssertEqual(output.components(separatedBy: "hook --agent codex PreToolUse").count - 1, 1)
    }
}
