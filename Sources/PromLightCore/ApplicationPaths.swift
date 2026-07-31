import Foundation

public enum ApplicationPaths {
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PROM_LIGHT_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PromLight Universal", isDirectory: true)
    }

    public static var events: URL { supportDirectory.appendingPathComponent("events.json") }
    public static var devices: URL { supportDirectory.appendingPathComponent("devices.json") }
    public static var config: URL { supportDirectory.appendingPathComponent("config.json") }
    public static var launchAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.promlight.universal.plist")
    }

    public static func createSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}
