import Foundation

public enum SupportedAgent: String, CaseIterable, Sendable {
    case claude, codex, cursor, copilot, qoder, codebuddy, antigravity
}

public enum HookInstallScope: Sendable {
    case global
    case project(URL)
    case local(URL)
}

public struct HookInstallResult: Sendable {
    public var agent: SupportedAgent
    public var destination: URL
}

public enum HookInstallerError: Error, CustomStringConvertible {
    case unsupportedProjectScope(SupportedAgent)
    case invalidExistingJSON(URL)

    public var description: String {
        switch self {
        case .unsupportedProjectScope(let agent): return "\(agent.rawValue) only supports global hook installation"
        case .invalidExistingJSON(let url): return "Existing hook configuration is not a JSON object: \(url.path)"
        }
    }
}

public enum HookInstaller {
    public static func isInstalled(_ agent: SupportedAgent) -> Bool {
        let directory = agent == .antigravity
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
            : globalDirectory(agent)
        return FileManager.default.fileExists(atPath: directory.path)
    }

    public static func install(
        agent: SupportedAgent,
        scope: HookInstallScope,
        executableURL: URL
    ) throws -> HookInstallResult {
        let destination = try destination(agent: agent, scope: scope)
        let template = template(agent: agent, executableURL: executableURL)
        let existing = try readRoot(destination)
        let merged: [String: Any]
        if agent == .antigravity {
            var root = existing
            root["promlight"] = template["promlight"]
            merged = root
        } else {
            merged = merge(existing: existing, incoming: template) as? [String: Any] ?? template
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data([0x0A])).write(to: destination, options: .atomic)
        return HookInstallResult(agent: agent, destination: destination)
    }

    public static func template(agent: SupportedAgent, executableURL: URL) -> [String: Any] {
        let binary = shellQuote(executableURL.standardizedFileURL.path)
        func command(_ event: String) -> String { "\(binary) hook --agent \(agent.rawValue) \(event)" }
        func nested(_ event: String, matcher: String? = nil) -> [String: Any] {
            var wrapper: [String: Any] = ["hooks": [["type": "command", "command": command(event)]]]
            if let matcher { wrapper["matcher"] = matcher }
            return wrapper
        }
        func direct(_ event: String, includeType: Bool = false) -> [String: Any] {
            var value: [String: Any] = ["command": command(event)]
            if includeType { value["type"] = "command" }
            return value
        }

        let matcherEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied", "Elicitation"]
        switch agent {
        case .claude:
            let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "PermissionDenied", "Elicitation", "StopFailure", "Stop", "SessionEnd"]
            return ["hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, [nested($0, matcher: matcherEvents.contains($0) ? "*" : nil)]) })]
        case .codex:
            let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Stop"]
            return ["hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, [nested($0)]) })]
        case .cursor:
            let events = ["sessionStart", "beforeSubmitPrompt", "afterFileEdit", "postToolUse", "beforeShellExecution", "beforeMCPExecution", "stop", "sessionEnd"]
            return ["version": 1, "hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, [direct($0)]) })]
        case .copilot:
            let events = ["sessionStart", "userPromptSubmitted", "postToolUse", "agentStop", "errorOccurred", "sessionEnd"]
            return ["version": 1, "hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, [direct($0, includeType: true)]) })]
        case .qoder:
            let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop"]
            return ["hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, [nested($0, matcher: matcherEvents.contains($0) ? "*" : nil)]) })]
        case .codebuddy:
            let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "StopFailure", "Stop", "SessionEnd"]
            return ["hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, [nested($0, matcher: matcherEvents.contains($0) ? "*" : nil)]) })]
        case .antigravity:
            // Antigravity's current schema groups tool events but uses flat
            // handlers for invocation and stop events. Avoid PreToolUse here:
            // it is a policy gate, while PromLight is passive telemetry only.
            return [
                "promlight": [
                    "enabled": true,
                    "PreInvocation": [direct("PreInvocation", includeType: true)],
                    "PostToolUse": [nested("PostToolUse", matcher: "*")],
                    "PostInvocation": [direct("PostInvocation", includeType: true)],
                    "Stop": [direct("Stop", includeType: true)],
                ],
            ]
        }
    }

    private static func destination(agent: SupportedAgent, scope: HookInstallScope) throws -> URL {
        switch scope {
        case .global:
            return globalDirectory(agent).appendingPathComponent(fileName(agent, local: false))
        case .project(let root):
            if agent == .copilot { throw HookInstallerError.unsupportedProjectScope(agent) }
            let directory: String
            switch agent {
            case .claude: directory = ".claude"
            case .codex: directory = ".codex"
            case .cursor: directory = ".cursor"
            case .qoder: directory = ".qoder"
            case .codebuddy: directory = ".codebuddy"
            case .antigravity: directory = ".agents"
            case .copilot: preconditionFailure()
            }
            return root.appendingPathComponent(directory, isDirectory: true).appendingPathComponent(fileName(agent, local: true))
        case .local(let directory):
            return directory.appendingPathComponent("promlight-\(agent.rawValue)-\(fileName(agent, local: false))")
        }
    }

    private static func globalDirectory(_ agent: SupportedAgent) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch agent {
        case .claude: return home.appendingPathComponent(".claude", isDirectory: true)
        case .codex: return home.appendingPathComponent(".codex", isDirectory: true)
        case .cursor: return home.appendingPathComponent(".cursor", isDirectory: true)
        case .copilot: return home.appendingPathComponent(".copilot", isDirectory: true)
        case .qoder: return home.appendingPathComponent(".qoder", isDirectory: true)
        case .codebuddy: return home.appendingPathComponent(".codebuddy", isDirectory: true)
        case .antigravity: return home.appendingPathComponent(".gemini/config", isDirectory: true)
        }
    }

    private static func fileName(_ agent: SupportedAgent, local: Bool) -> String {
        switch agent {
        case .claude, .qoder, .codebuddy: return local ? "settings.local.json" : "settings.json"
        case .codex, .cursor, .antigravity: return "hooks.json"
        case .copilot: return "settings.json"
        }
    }

    private static func readRoot(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let root = object as? [String: Any] else { throw HookInstallerError.invalidExistingJSON(url) }
        return root
    }

    private static func merge(existing: Any, incoming: Any) -> Any {
        if let old = existing as? [String: Any], let new = incoming as? [String: Any] {
            var result = old
            for (key, value) in new { result[key] = merge(existing: result[key] as Any, incoming: value) }
            return result
        }
        if let old = existing as? [Any], let new = incoming as? [Any] {
            return old.compactMap(sanitizeLegacyPromLight) + new
        }
        return incoming
    }

    private static func sanitizeLegacyPromLight(_ value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            if let command = dictionary["command"] as? String, isPromLightCommand(command) {
                return nil
            }
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                if let sanitized = sanitizeLegacyPromLight(child) { result[key] = sanitized }
            }
            if dictionary["hooks"] != nil, let hooks = result["hooks"] as? [Any], hooks.isEmpty {
                return nil
            }
            return result.isEmpty ? nil : result
        }
        if let array = value as? [Any] { return array.compactMap(sanitizeLegacyPromLight) }
        return value
    }

    private static func isPromLightCommand(_ string: String) -> Bool {
        let lower = string.lowercased()
        return (lower.contains("promlight") && lower.contains("agent_hook.py")) ||
            (lower.contains("promlight") && lower.contains("hook --agent"))
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
