import Foundation
import Network

protocol DaemonLightExecuting: Sendable {
    @discardableResult
    func execute(script: String, deviceSelector: String?) throws -> [InstructionResult]
}

extension LightController: DaemonLightExecuting {}

enum HookMessageStreamError: Error, Equatable, CustomStringConvertible {
    case invalidJSON(String)
    case lineTooLong(Int)
    case missingNewline(Int)

    var description: String {
        switch self {
        case .invalidJSON(let detail):
            return "Invalid hook JSON: \(detail)"
        case .lineTooLong(let count):
            return "Hook JSON line exceeds the byte limit (\(count) bytes)"
        case .missingNewline(let count):
            return "Hook connection ended with an incomplete JSON line (\(count) bytes)"
        }
    }
}

struct HookMessageStreamDecoder {
    private(set) var buffer = Data()
    let maximumLineBytes: Int

    init(maximumLineBytes: Int = 1_048_576) {
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    mutating func append(_ data: Data) throws -> [Result<HookMessage, HookMessageStreamError>] {
        buffer.append(data)
        var messages: [Result<HookMessage, HookMessageStreamError>] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }
            guard line.count <= maximumLineBytes else {
                messages.append(.failure(.lineTooLong(line.count)))
                continue
            }

            do {
                messages.append(.success(try JSONDecoder().decode(HookMessage.self, from: line)))
            } catch {
                messages.append(.failure(.invalidJSON(String(describing: error))))
            }
        }

        guard buffer.count <= maximumLineBytes else {
            let count = buffer.count
            buffer.removeAll(keepingCapacity: false)
            throw HookMessageStreamError.lineTooLong(count)
        }
        return messages
    }

    mutating func finish() -> HookMessageStreamError? {
        guard !buffer.isEmpty else { return nil }
        let count = buffer.count
        buffer.removeAll(keepingCapacity: false)
        return .missingNewline(count)
    }
}

private enum DaemonMessageError: Error, CustomStringConvertible {
    case emptyCommand

    var description: String {
        switch self {
        case .emptyCommand:
            return "Hook message contains no command"
        }
    }
}

private final class PromLightDaemonState: @unchecked Sendable {
    private let lock = NSLock()
    private let eventCapacity: Int
    private let sessionCapacity: Int
    private var lifecycle: PromLightDaemonLifecycle = .stopped
    private var startedAt: Date?
    private var eventLog: [PromLightDaemonEvent] = []
    private var sessionLog: [String: PromLightSessionMetadata] = [:]
    private var totalEvents = 0
    private var successfulEvents = 0
    private var failedEvents = 0
    private var lastError: String?

    init(eventCapacity: Int) {
        self.eventCapacity = max(1, eventCapacity)
        self.sessionCapacity = max(1, eventCapacity)
    }

    func transition(to lifecycle: PromLightDaemonLifecycle, at timestamp: Date, error: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.lifecycle = lifecycle
        if lifecycle == .starting { startedAt = timestamp }
        if lifecycle == .stopped { startedAt = nil }
        if let error { lastError = error }
    }

    @discardableResult
    func record(
        message: HookMessage,
        at timestamp: Date,
        success: Bool,
        error: String?
    ) -> PromLightDaemonEvent {
        let event = PromLightDaemonEvent(
            timestamp: timestamp,
            agent: message.agent,
            session: message.session,
            cwd: message.cwd,
            message: message.message,
            command: message.cmd,
            success: success,
            error: error,
            releaseSession: message.releaseSession,
            notice: message.notice
        )

        lock.lock()
        defer { lock.unlock() }
        append(event)
        updateSession(from: message, at: timestamp)
        return event
    }

    @discardableResult
    func recordProtocolError(_ error: String, at timestamp: Date) -> PromLightDaemonEvent {
        let event = PromLightDaemonEvent(
            timestamp: timestamp,
            agent: "",
            session: nil,
            cwd: nil,
            message: "Rejected hook payload",
            command: "",
            success: false,
            error: error,
            releaseSession: false,
            notice: ""
        )

        lock.lock()
        defer { lock.unlock() }
        append(event)
        return event
    }

    func events(limit: Int?) -> [PromLightDaemonEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard let limit else { return eventLog }
        guard limit > 0 else { return [] }
        return Array(eventLog.suffix(limit))
    }

    func sessions() -> [PromLightSessionMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return sessionLog.values.sorted {
            if $0.lastSeenAt == $1.lastSeenAt { return $0.session < $1.session }
            return $0.lastSeenAt > $1.lastSeenAt
        }
    }

    func status(host: String, port: UInt16) -> PromLightDaemonStatus {
        lock.lock()
        defer { lock.unlock() }
        let activeSessions = sessionLog.values.lazy.filter { !$0.isReleased }.count
        return PromLightDaemonStatus(
            host: host,
            port: port,
            lifecycle: lifecycle,
            startedAt: startedAt,
            eventCount: eventLog.count,
            totalEvents: totalEvents,
            successfulEvents: successfulEvents,
            failedEvents: failedEvents,
            activeSessionCount: activeSessions,
            releasedSessionCount: sessionLog.count - activeSessions,
            lastError: lastError
        )
    }

    private func append(_ event: PromLightDaemonEvent) {
        eventLog.append(event)
        if eventLog.count > eventCapacity {
            eventLog.removeFirst(eventLog.count - eventCapacity)
        }
        totalEvents += 1
        if event.success {
            successfulEvents += 1
        } else {
            failedEvents += 1
            lastError = event.error
        }
    }

    private func updateSession(from message: HookMessage, at timestamp: Date) {
        guard let session = message.session, !session.isEmpty else { return }
        if var metadata = sessionLog[session] {
            metadata.agent = message.agent
            metadata.cwd = message.cwd ?? metadata.cwd
            metadata.lastSeenAt = timestamp
            metadata.releasedAt = message.releaseSession ? timestamp : nil
            sessionLog[session] = metadata
        } else {
            sessionLog[session] = PromLightSessionMetadata(
                session: session,
                agent: message.agent,
                cwd: message.cwd,
                firstSeenAt: timestamp,
                lastSeenAt: timestamp,
                releasedAt: message.releaseSession ? timestamp : nil
            )
        }

        guard sessionLog.count > sessionCapacity else { return }
        let overflow = sessionLog.count - sessionCapacity
        let oldest = sessionLog.values.sorted {
            if $0.isReleased != $1.isReleased { return $0.isReleased }
            return $0.lastSeenAt < $1.lastSeenAt
        }.prefix(overflow)
        for metadata in oldest { sessionLog.removeValue(forKey: metadata.session) }
    }
}

private final class HookConnectionReader: @unchecked Sendable {
    private let connection: NWConnection
    private weak var daemon: PromLightDaemon?
    private var decoder = HookMessageStreamDecoder()
    private var finished = false
    private var keepAlive: HookConnectionReader?

    init(connection: NWConnection, daemon: PromLightDaemon) {
        self.connection = connection
        self.daemon = daemon
    }

    func start(on queue: DispatchQueue) {
        // NWConnection retains its callbacks, but they intentionally capture this
        // reader weakly. Keep the reader alive until the connection terminates.
        keepAlive = self
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveNext()
            case .failed(let error):
                self.finish(error: "Hook connection failed: \(error)")
            case .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                do {
                    for result in try self.decoder.append(data) {
                        switch result {
                        case .success(let message): self.daemon?.submit(message)
                        case .failure(let error): self.daemon?.recordProtocolError(error.description)
                        }
                    }
                } catch {
                    self.finish(error: String(describing: error))
                    return
                }
            }

            if let error {
                self.finish(error: "Hook connection receive failed: \(error)")
            } else if isComplete {
                self.finish()
            } else {
                self.receiveNext()
            }
        }
    }

    private func finish(error: String? = nil) {
        guard !finished else { return }
        finished = true
        if let error {
            daemon?.recordProtocolError(error)
        } else if let error = decoder.finish() {
            daemon?.recordProtocolError(error.description)
        }
        connection.cancel()
        keepAlive = nil
    }
}

public final class PromLightDaemon: @unchecked Sendable {
    public static let host = "127.0.0.1"
    public static let port: UInt16 = 47_800

    private let executor: any DaemonLightExecuting
    private let selectorProvider: @Sendable (HookMessage) -> String?
    private let state: PromLightDaemonState
    private let now: @Sendable () -> Date
    private let networkQueue = DispatchQueue(label: "com.promlight.daemon.network")
    private let hardwareQueue = DispatchQueue(label: "com.promlight.daemon.hardware")
    private let listenerLock = NSLock()
    private var listener: NWListener?
    public let listenPort: UInt16

    public convenience init(
        controller: LightController = LightController(),
        eventCapacity: Int = 500,
        port: UInt16 = PromLightDaemon.port,
        deviceSelectorProvider: @escaping @Sendable (HookMessage) -> String? = { _ in nil }
    ) {
        self.init(
            executor: controller,
            eventCapacity: eventCapacity,
            port: port,
            deviceSelectorProvider: deviceSelectorProvider
        )
    }

    init(
        executor: any DaemonLightExecuting,
        eventCapacity: Int = 500,
        port: UInt16 = PromLightDaemon.port,
        deviceSelectorProvider: @escaping @Sendable (HookMessage) -> String? = { _ in nil },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.executor = executor
        self.selectorProvider = deviceSelectorProvider
        self.state = PromLightDaemonState(eventCapacity: eventCapacity)
        self.listenPort = port
        self.now = now
    }

    public var status: PromLightDaemonStatus {
        state.status(host: Self.host, port: listenPort)
    }

    public func events(limit: Int? = nil) -> [PromLightDaemonEvent] {
        state.events(limit: limit)
    }

    public func sessions() -> [PromLightSessionMetadata] {
        state.sessions()
    }

    public func start() throws {
        listenerLock.lock()
        guard listener == nil else {
            listenerLock.unlock()
            throw PromLightDaemonError.alreadyStarted
        }

        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.acceptLocalOnly = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(IPv4Address(Self.host)!),
                port: NWEndpoint.Port(rawValue: listenPort)!
            )
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listenerLock.unlock()

            state.transition(to: .starting, at: now())
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                HookConnectionReader(connection: connection, daemon: self).start(on: self.networkQueue)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] listenerState in
                guard let self, let listener, self.isCurrent(listener) else { return }
                switch listenerState {
                case .setup:
                    self.state.transition(to: .starting, at: self.now())
                case .waiting(let error):
                    self.state.transition(to: .waiting, at: self.now(), error: String(describing: error))
                case .ready:
                    self.state.transition(to: .ready, at: self.now())
                case .failed(let error):
                    self.state.transition(to: .failed, at: self.now(), error: String(describing: error))
                    self.clearListenerIfCurrent(listener)
                case .cancelled:
                    self.state.transition(to: .stopped, at: self.now())
                    self.clearListenerIfCurrent(listener)
                @unknown default:
                    self.state.transition(to: .failed, at: self.now(), error: "Unknown listener state")
                }
            }
            listener.start(queue: networkQueue)
        } catch {
            listener = nil
            listenerLock.unlock()
            state.transition(to: .failed, at: now(), error: String(describing: error))
            throw error
        }
    }

    public func stop() {
        listenerLock.lock()
        let listener = self.listener
        self.listener = nil
        listenerLock.unlock()
        listener?.cancel()
        state.transition(to: .stopped, at: now())
    }

    public func submit(
        _ message: HookMessage,
        completion: (@Sendable (PromLightDaemonEvent) -> Void)? = nil
    ) {
        hardwareQueue.async { [self] in
            let timestamp = now()
            let error: String?
            if message.cmd.isEmpty {
                error = message.releaseSession ? nil : DaemonMessageError.emptyCommand.description
            } else {
                do {
                    try executor.execute(script: message.cmd, deviceSelector: selectorProvider(message))
                    error = nil
                } catch let executionError {
                    error = String(describing: executionError)
                }
            }
            let event = state.record(message: message, at: timestamp, success: error == nil, error: error)
            completion?(event)
        }
    }

    fileprivate func recordProtocolError(_ error: String) {
        state.recordProtocolError(error, at: now())
    }

    private func isCurrent(_ candidate: NWListener) -> Bool {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        return listener === candidate
    }

    private func clearListenerIfCurrent(_ candidate: NWListener) {
        listenerLock.lock()
        if listener === candidate { listener = nil }
        listenerLock.unlock()
    }
}
