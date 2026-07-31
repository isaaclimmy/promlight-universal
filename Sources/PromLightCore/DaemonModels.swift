import Foundation

public enum PromLightDaemonLifecycle: String, Codable, Equatable, Sendable {
    case stopped
    case starting
    case ready
    case waiting
    case failed
}

public struct PromLightDaemonEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let agent: String
    public let session: String?
    public let cwd: String?
    public let message: String
    public let command: String
    public let success: Bool
    public let error: String?
    public let releaseSession: Bool
    public let notice: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        agent: String,
        session: String?,
        cwd: String?,
        message: String,
        command: String,
        success: Bool,
        error: String?,
        releaseSession: Bool,
        notice: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.agent = agent
        self.session = session
        self.cwd = cwd
        self.message = message
        self.command = command
        self.success = success
        self.error = error
        self.releaseSession = releaseSession
        self.notice = notice
    }
}

public struct PromLightSessionMetadata: Codable, Equatable, Sendable {
    public let session: String
    public var agent: String
    public var cwd: String?
    public let firstSeenAt: Date
    public var lastSeenAt: Date
    public var releasedAt: Date?

    public var isReleased: Bool { releasedAt != nil }

    public init(
        session: String,
        agent: String,
        cwd: String?,
        firstSeenAt: Date,
        lastSeenAt: Date,
        releasedAt: Date?
    ) {
        self.session = session
        self.agent = agent
        self.cwd = cwd
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.releasedAt = releasedAt
    }
}

public struct PromLightDaemonStatus: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let lifecycle: PromLightDaemonLifecycle
    public let startedAt: Date?
    public let eventCount: Int
    public let totalEvents: Int
    public let successfulEvents: Int
    public let failedEvents: Int
    public let activeSessionCount: Int
    public let releasedSessionCount: Int
    public let lastError: String?

    public init(
        host: String,
        port: UInt16,
        lifecycle: PromLightDaemonLifecycle,
        startedAt: Date?,
        eventCount: Int,
        totalEvents: Int,
        successfulEvents: Int,
        failedEvents: Int,
        activeSessionCount: Int,
        releasedSessionCount: Int,
        lastError: String?
    ) {
        self.host = host
        self.port = port
        self.lifecycle = lifecycle
        self.startedAt = startedAt
        self.eventCount = eventCount
        self.totalEvents = totalEvents
        self.successfulEvents = successfulEvents
        self.failedEvents = failedEvents
        self.activeSessionCount = activeSessionCount
        self.releasedSessionCount = releasedSessionCount
        self.lastError = lastError
    }
}

public enum PromLightDaemonError: Error, Equatable, CustomStringConvertible {
    case alreadyStarted

    public var description: String {
        switch self {
        case .alreadyStarted:
            return "The PromLight daemon is already started"
        }
    }
}

