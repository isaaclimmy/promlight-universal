import Foundation
import XCTest
@testable import PromLightCore

final class HeadlessDaemonTests: XCTestCase {
    func testStreamDecoderAcceptsFragmentedAndMultipleMessages() throws {
        let first = message(command: "led green on", session: "one")
        let second = message(command: "led red blink", session: "two")
        let wire = try JSONEncoder().encode(first) + Data([0x0A]) + JSONEncoder().encode(second) + Data([0x0A])
        let split = wire.count / 2
        var decoder = HookMessageStreamDecoder()

        let prefix = try decoder.append(Data(wire.prefix(split)))
        let suffix = try decoder.append(Data(wire.suffix(from: split)))
        let decoded = (prefix + suffix).compactMap { try? $0.get() }

        XCTAssertEqual(decoded, [first, second])
        XCTAssertNil(decoder.finish())
    }

    func testStreamDecoderRejectsIncompleteLineWithoutUsingAListener() throws {
        var decoder = HookMessageStreamDecoder()
        XCTAssertTrue(try decoder.append(Data("{\"cmd\":\"led green on\"}".utf8)).isEmpty)
        XCTAssertEqual(decoder.finish(), .missingNewline(22))
    }

    func testEventLogIsBoundedAndTracksFailures() {
        let executor = MockLightExecutor(failingCommand: "bad")
        let daemon = PromLightDaemon(executor: executor, eventCapacity: 2)
        let completed = expectation(description: "all commands complete")
        completed.expectedFulfillmentCount = 3

        daemon.submit(message(command: "one", session: "1")) { _ in completed.fulfill() }
        daemon.submit(message(command: "bad", session: "2")) { _ in completed.fulfill() }
        daemon.submit(message(command: "three", session: "3")) { _ in completed.fulfill() }
        wait(for: [completed], timeout: 2)

        XCTAssertEqual(daemon.events().map(\ .command), ["bad", "three"])
        XCTAssertEqual(daemon.status.eventCount, 2)
        XCTAssertEqual(daemon.status.totalEvents, 3)
        XCTAssertEqual(daemon.status.successfulEvents, 2)
        XCTAssertEqual(daemon.status.failedEvents, 1)
        XCTAssertNotNil(daemon.events().first?.error)
    }

    func testHardwareExecutionIsSerialized() {
        let executor = MockLightExecutor(delay: 0.01)
        let daemon = PromLightDaemon(executor: executor)
        let completed = expectation(description: "all commands complete")
        completed.expectedFulfillmentCount = 12

        for index in 0..<12 {
            daemon.submit(message(command: "command-\(index)", session: nil)) { _ in completed.fulfill() }
        }
        wait(for: [completed], timeout: 3)

        XCTAssertEqual(executor.maximumConcurrentExecutions, 1)
        XCTAssertEqual(executor.commands, (0..<12).map { "command-\($0)" })
    }

    func testReleaseOnlyMessageSkipsHardwareAndReleasesSession() throws {
        let executor = MockLightExecutor()
        let daemon = PromLightDaemon(executor: executor)
        let completed = expectation(description: "release recorded")
        daemon.submit(message(command: "", session: "session-1", releaseSession: true)) { event in
            XCTAssertTrue(event.success)
            XCTAssertTrue(event.releaseSession)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)

        XCTAssertTrue(executor.commands.isEmpty)
        let metadata = try XCTUnwrap(daemon.sessions().first)
        XCTAssertEqual(metadata.session, "session-1")
        XCTAssertTrue(metadata.isReleased)
        XCTAssertEqual(daemon.status.activeSessionCount, 0)
        XCTAssertEqual(daemon.status.releasedSessionCount, 1)
    }

    func testDeviceSelectorProviderRoutesHardwareExecution() {
        let executor = MockLightExecutor()
        let daemon = PromLightDaemon(
            executor: executor,
            deviceSelectorProvider: { message in message.cwd == "/tmp/project" ? "39CA" : nil }
        )
        let completed = expectation(description: "routed command complete")
        daemon.submit(message(command: "led green on", session: nil)) { _ in completed.fulfill() }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(executor.selectors, ["39CA"])
    }

    private func message(
        command: String,
        session: String?,
        releaseSession: Bool = false
    ) -> HookMessage {
        HookMessage(
            cmd: command,
            message: "test event",
            session: session,
            cwd: "/tmp/project",
            agent: "codex",
            releaseSession: releaseSession,
            notice: ""
        )
    }
}

private enum MockExecutionError: Error {
    case rejected
}

private final class MockLightExecutor: DaemonLightExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private let failingCommand: String?
    private var commandLog: [String] = []
    private var selectorLog: [String?] = []
    private var concurrentExecutions = 0
    private var maximumConcurrency = 0

    init(delay: TimeInterval = 0, failingCommand: String? = nil) {
        self.delay = delay
        self.failingCommand = failingCommand
    }

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return commandLog
    }

    var maximumConcurrentExecutions: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumConcurrency
    }

    var selectors: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return selectorLog
    }

    func execute(script: String, deviceSelector: String?) throws -> [InstructionResult] {
        lock.lock()
        commandLog.append(script)
        selectorLog.append(deviceSelector)
        concurrentExecutions += 1
        maximumConcurrency = max(maximumConcurrency, concurrentExecutions)
        lock.unlock()

        if delay > 0 { Thread.sleep(forTimeInterval: delay) }

        lock.lock()
        concurrentExecutions -= 1
        lock.unlock()
        if script == failingCommand { throw MockExecutionError.rejected }
        return []
    }
}
