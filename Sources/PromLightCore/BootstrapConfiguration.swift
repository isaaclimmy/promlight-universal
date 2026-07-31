import Foundation

public struct ApplicationConfiguration: Codable, Equatable, Sendable {
    public var hookPort: UInt16
    public var webPort: UInt16
    public var openBrowser: Bool

    enum CodingKeys: String, CodingKey {
        case hookPort = "port"
        case webPort = "web_port"
        case openBrowser = "open_browser"
    }

    public init(hookPort: UInt16 = 47_800, webPort: UInt16 = 7_800, openBrowser: Bool = true) {
        self.hookPort = hookPort
        self.webPort = webPort
        self.openBrowser = openBrowser
    }

    public static func load(from url: URL = ApplicationPaths.config) throws -> ApplicationConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return ApplicationConfiguration() }
        return try JSONDecoder().decode(ApplicationConfiguration.self, from: Data(contentsOf: url))
    }
}

public enum BootstrapConfiguration {
    public static func ensureDefaults() throws {
        try ApplicationPaths.createSupportDirectory()
        try writeIfMissing(
            try JSONEncoder.pretty.encode(ApplicationConfiguration()),
            to: ApplicationPaths.config
        )
        try writeIfMissing(
            try JSONSerialization.data(withJSONObject: [
                "macros": EventConfiguration.defaultMacros,
                "events": EventConfiguration.defaultEvents,
            ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([0x0A]),
            to: ApplicationPaths.events
        )
        try writeIfMissing(
            try JSONSerialization.data(withJSONObject: [
                "aliases": [:],
                "routes": [:],
                "agents": [:],
                "default": NSNull(),
            ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([0x0A]),
            to: ApplicationPaths.devices
        )
    }

    private static func writeIfMissing(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try data.write(to: url, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
