import Foundation

public enum ServiceInstallerError: Error, CustomStringConvertible {
    case launchctlFailed(String)

    public var description: String {
        switch self {
        case .launchctlFailed(let message): return "launchctl failed: \(message)"
        }
    }
}

public enum ServiceInstaller {
    public static let label = "com.promlight.universal"

    public static func manifest(executableURL: URL) throws -> Data {
        let logDirectory = ApplicationPaths.supportDirectory.appendingPathComponent("Logs", isDirectory: true)
        let root: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.standardizedFileURL.path, "--headless"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": logDirectory.appendingPathComponent("daemon.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("daemon-error.log").path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    public static func enable(executableURL: URL) throws -> URL {
        let destination = ApplicationPaths.launchAgent
        try ApplicationPaths.createSupportDirectory()
        try FileManager.default.createDirectory(
            at: ApplicationPaths.supportDirectory.appendingPathComponent("Logs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifest(executableURL: executableURL).write(to: destination, options: .atomic)
        return destination
    }

    public static func disable() throws {
        let destination = ApplicationPaths.launchAgent
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        let domain = "gui/\(getuid())"
        _ = try? runLaunchctl(["bootout", domain, destination.path])
        try FileManager.default.removeItem(at: destination)
    }

    public static func load() throws {
        let destination = ApplicationPaths.launchAgent
        let domain = "gui/\(getuid())"
        let result = try runLaunchctl(["bootstrap", domain, destination.path])
        if result.status != 0 && !result.output.localizedCaseInsensitiveContains("already") && !result.output.contains("5:") {
            throw ServiceInstallerError.launchctlFailed(result.output)
        }
    }

    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: ApplicationPaths.launchAgent.path)
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
