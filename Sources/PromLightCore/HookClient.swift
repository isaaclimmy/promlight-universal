import Darwin
import Foundation

public struct HookMessage: Codable, Equatable, Sendable {
    public var cmd: String
    public var message: String
    public var session: String?
    public var cwd: String?
    public var agent: String
    public var releaseSession: Bool
    public var notice: String

    public init(
        cmd: String,
        message: String,
        session: String?,
        cwd: String?,
        agent: String,
        releaseSession: Bool,
        notice: String
    ) {
        self.cmd = cmd
        self.message = message
        self.session = session
        self.cwd = cwd
        self.agent = agent
        self.releaseSession = releaseSession
        self.notice = notice
    }

    enum CodingKeys: String, CodingKey {
        case cmd, message, session, cwd, agent, notice
        case releaseSession = "release_session"
    }
}

public enum HookClient {
    public static let knownAgents = ["claude", "codex", "cursor", "copilot", "qoder", "codebuddy", "antigravity"]
    public static let sessionEndEvents: Set<String> = ["SessionEnd", "sessionEnd"]

    public static func gateDecision(agent: String, event: String) -> [String: Any]? {
        if agent == "antigravity" {
            // Empty objects satisfy passive Antigravity hook contracts. Stop
            // requires a decision; any value other than "continue" permits
            // normal termination without changing tool permissions.
            switch event {
            case "Stop": return ["decision": "allow"]
            case "PreInvocation", "PostToolUse", "PostInvocation": return [:]
            default: return nil
            }
        }
        guard agent == "cursor" else { return nil }
        switch event {
        case "beforeSubmitPrompt", "beforeShellExecution", "beforeMCPExecution":
            // PromLight observes agent activity; it never acts as a policy gate.
            return ["continue": true]
        default: return nil
        }
    }

    public static func buildMessage(
        event fallbackEvent: String?,
        agent rawAgent: String,
        input: Data,
        eventsURL: URL = ApplicationPaths.events
    ) -> HookMessage? {
        let payload = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any]) ?? [:]
        let agent = knownAgents.contains(rawAgent.lowercased()) ? rawAgent.lowercased() : ""
        let event = (payload["hook_event_name"] as? String) ?? fallbackEvent ?? ""
        guard !event.isEmpty else { return nil }

        let configuration: EventConfiguration
        let notice: String
        do {
            configuration = try EventConfiguration.load(from: eventsURL)
            notice = ""
        } catch {
            configuration = EventConfiguration()
            notice = "events.json is invalid, so PromLight is using defaults. Check \(eventsURL.path): \(error)"
        }
        let command = configuration.command(for: event) ?? ""
        let release = sessionEndEvents.contains(event) ||
            (agent == "antigravity" && event == "Stop" && (payload["fullyIdle"] as? Bool) != false)
        guard !command.isEmpty || release else { return nil }

        return HookMessage(
            cmd: command,
            message: summarize(event: event, payload: payload),
            session: string(payload["session_id"]) ?? string(payload["conversation_id"]) ??
                string(payload["sessionId"]) ?? string(payload["conversationId"]),
            cwd: normalizedCWD(payload),
            agent: agent,
            releaseSession: release,
            notice: notice
        )
    }

    @discardableResult
    public static func send(_ message: HookMessage, port: UInt16? = nil) -> Bool {
        let port = port ?? resolvedPort()
        guard let data = try? JSONEncoder().encode(message) + Data([0x0A]) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { return false }
        let originalFlags = fcntl(descriptor, F_GETFL, 0)
        guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else { return false }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { return false }
            var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&readiness, 1, 300) > 0 else { return false }
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0,
                  socketError == 0 else { return false }
        }
        guard fcntl(descriptor, F_SETFL, originalFlags) == 0 else { return false }
        var sendTimeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(descriptor, base.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    public static func resolvedPort() -> UInt16 {
        if let raw = ProcessInfo.processInfo.environment["PROM_LIGHT_PORT"], let port = UInt16(raw), port > 0 {
            return port
        }
        return (try? ApplicationConfiguration.load().hookPort) ?? 47_800
    }

    private static func normalizedCWD(_ payload: [String: Any]) -> String? {
        if let cwd = string(payload["cwd"]), !cwd.isEmpty { return cwd }
        let roots = (payload["workspace_roots"] as? [Any]) ?? (payload["workspacePaths"] as? [Any])
        guard let first = roots?.first else { return nil }
        if let root = first as? String { return root }
        if let root = first as? [String: Any] {
            return string(root["path"]) ?? string(root["root"]) ?? string(root["uri"])
        }
        return nil
    }

    private static func summarize(event: String, payload: [String: Any]) -> String {
        let fieldMap: [String: [String]] = [
            "SessionStart": ["source"], "UserPromptSubmit": ["prompt"],
            "PreToolUse": ["tool_name"], "PostToolUse": ["tool_name"],
            "PostToolUseFailure": ["tool_name"], "PermissionRequest": ["tool_name"],
            "PermissionDenied": ["tool_name"], "SubagentStart": ["agent_type"],
            "SubagentStop": ["agent_type"], "PreCompact": ["trigger"],
            "PostCompact": ["trigger"], "SessionEnd": ["reason"],
            "StopFailure": ["error_type"], "beforeSubmitPrompt": ["prompt"],
            "afterFileEdit": ["file_path"], "beforeShellExecution": ["command"],
            "userPromptSubmitted": ["prompt"], "postToolUse": ["toolName"],
            "agentStop": ["stopReason"], "errorOccurred": ["error"],
            "PreInvocation": ["invocationNum"], "PostInvocation": ["invocationNum"],
            "Stop": ["terminationReason"],
        ]
        let detail = (fieldMap[event] ?? []).compactMap { key -> String? in
            guard let value = string(payload[key]), !value.isEmpty else { return nil }
            return "\(key)=\(clip(value))"
        }.joined(separator: "  ")
        return detail.isEmpty ? event : "\(event)  \(detail)"
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value, !(value is NSNull) { return String(describing: value) }
        return nil
    }

    private static func clip(_ value: String, limit: Int = 120) -> String {
        let collapsed = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }
}
