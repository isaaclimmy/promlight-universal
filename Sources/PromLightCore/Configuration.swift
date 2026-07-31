import Foundation

public struct EventConfiguration: Sendable {
    public var macros: [String: String]
    public var events: [String: String]

    public init(macros: [String: String] = [:], events: [String: String] = [:]) {
        self.macros = Self.defaultMacros.merging(macros) { _, new in new }
        self.events = Self.defaultEvents.merging(events) { _, new in new }
    }

    public static let defaultMacros: [String: String] = [
        "work": "led yellow on --only",
        "await": "led yellow blink --only",
        "idle": "led green on --only",
        "error": "led red blink --only",
        "start": "led all blink --only --count 2 ; wait 2s ; led green on",
        "end": "led green blink --freq 4000 --fade 2000",
    ]

    public static let defaultEvents: [String: String] = [
        "SessionStart": "start",
        "UserPromptSubmit": "work",
        "PreToolUse": "work",
        "PostToolUse": "work",
        "PostToolUseFailure": "error",
        "PermissionRequest": "await",
        "PermissionDenied": "await",
        "Elicitation": "await",
        "SubagentStart": "work",
        "SubagentStop": "work",
        "PreCompact": "work",
        "PostCompact": "work",
        "Stop": "idle",
        "SessionEnd": "end",
        "StopFailure": "error",
        "sessionStart": "start",
        "beforeSubmitPrompt": "work",
        "afterFileEdit": "work",
        "postToolUse": "work",
        "beforeShellExecution": "await",
        "beforeMCPExecution": "await",
        "stop": "idle",
        "sessionEnd": "end",
        "userPromptSubmitted": "work",
        "agentStop": "idle",
        "errorOccurred": "error",
        "PreInvocation": "work",
        "PostInvocation": "work",
    ]

    public func command(for event: String) -> String? {
        guard let mapped = events[event] else { return nil }
        return expand(mapped, seen: [], depth: 0)
    }

    private func expand(_ value: String, seen: Set<String>, depth: Int) -> String {
        guard depth < 8 else { return value }
        return value
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { clause in
                let key = clause.lowercased()
                guard let macro = macros[key], !seen.contains(key) else { return clause }
                return expand(macro, seen: seen.union([key]), depth: depth + 1)
            }
            .joined(separator: " ; ")
    }

    public static func load(from url: URL) throws -> EventConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return EventConfiguration() }
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ConfigurationError.invalidRoot(url)
        }
        return EventConfiguration(
            macros: stringDictionary(root["macros"]),
            events: stringDictionary(root["events"])
        )
    }

    private static func stringDictionary(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [:]) { result, item in
            if let string = item.value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[item.key] = string
            }
        }
    }
}

public struct DeviceConfiguration: Sendable {
    public var aliases: [String: String]
    public var routes: [String: String]
    public var agents: [String: String]
    public var defaultDevice: String?

    public init(
        aliases: [String: String] = [:],
        routes: [String: String] = [:],
        agents: [String: String] = [:],
        defaultDevice: String? = nil
    ) {
        self.aliases = aliases
        self.routes = routes
        self.agents = agents
        self.defaultDevice = defaultDevice
    }

    public func route(cwd: String?, agent: String?) -> String? {
        if let cwd {
            let normalized = URL(fileURLWithPath: cwd).standardizedFileURL.path
            let best = routes
                .filter { normalized == URL(fileURLWithPath: $0.key).standardizedFileURL.path || normalized.hasPrefix(URL(fileURLWithPath: $0.key).standardizedFileURL.path + "/") }
                .max { $0.key.count < $1.key.count }
            if let best { return best.value }
        }
        if let agent, let device = agents[agent.lowercased()] { return device }
        return defaultDevice
    }

    public func resolvedRoute(cwd: String?, agent: String?) -> String? {
        resolve(route(cwd: cwd, agent: agent))
    }

    public func resolve(_ selector: String?) -> String? {
        guard var selector, !selector.isEmpty else { return nil }
        var seen = Set<String>()
        while let next = aliases[selector], !seen.contains(selector.lowercased()) {
            seen.insert(selector.lowercased())
            selector = next
        }
        return selector
    }

    public static func load(from url: URL) throws -> DeviceConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return DeviceConfiguration() }
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { throw ConfigurationError.invalidRoot(url) }
        return DeviceConfiguration(
            aliases: stringDictionary(root["aliases"]),
            routes: stringDictionary(root["routes"]),
            agents: stringDictionary(root["agents"]),
            defaultDevice: root["default"] as? String
        )
    }

    private static func stringDictionary(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [:]) { result, item in
            if let string = item.value as? String, !string.isEmpty { result[item.key] = string }
        }
    }
}

public enum ConfigurationError: Error, CustomStringConvertible {
    case invalidRoot(URL)

    public var description: String {
        switch self {
        case .invalidRoot(let url): return "Configuration must contain a JSON object: \(url.path)"
        }
    }
}
