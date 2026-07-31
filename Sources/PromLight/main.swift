import Darwin
import Foundation
import PromLightCore

private let sourceVersion = "0.2.1"
private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? sourceVersion
}
private let arguments = Array(CommandLine.arguments.dropFirst())

func printHelp() {
    print("""
    PromLight Universal — native macOS PromLight daemon and CLI

    Usage:
      PromLight devices              List connected PromLight devices
      PromLight battery              Show the connected PromLight battery level
      PromLight test                 Run a short yellow light test
      PromLight command SCRIPT       Run a light command or script
      PromLight read PARAMETER       Read a persistent device parameter
      PromLight setup <agent|all>    Install AI hooks
      PromLight hook --agent A E     Forward one AI hook event
      PromLight autostart <COMMAND>  Enable, disable, or inspect login startup
      PromLight --headless           Start the background service
      PromLight --selftest           Validate protocol and connected hardware
      PromLight --diag-open          Diagnose native HID access
      PromLight --version            Print the version
    """)
}

func executableURL() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
}

func localPortIsOpen(_ port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { return false }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

func openLocalConsole(port: UInt16) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["http://127.0.0.1:\(port)/"]
    try? process.run()
}

func runHook(_ arguments: [String]) {
    var agent = ""
    var positionalEvent: String?
    var index = 1
    while index < arguments.count {
        let value = arguments[index]
        if value == "--agent" {
            if index + 1 < arguments.count { agent = arguments[index + 1] }
            index += 2
        } else if value.hasPrefix("--agent=") {
            agent = String(value.dropFirst("--agent=".count))
            index += 1
        } else {
            if positionalEvent == nil && !value.hasPrefix("-") { positionalEvent = value }
            index += 1
        }
    }

    let input = isatty(STDIN_FILENO) == 0 ? FileHandle.standardInput.readDataToEndOfFile() : Data()
    let payload = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any]) ?? [:]
    let event = (payload["hook_event_name"] as? String) ?? positionalEvent ?? ProcessInfo.processInfo.environment["PROM_LIGHT_HOOK_EVENT"] ?? ""
    let normalizedAgent = agent.lowercased()

    if let decision = HookClient.gateDecision(agent: normalizedAgent, event: event),
       let data = try? JSONSerialization.data(withJSONObject: decision),
       let output = String(data: data, encoding: .utf8) {
        print(output)
        fflush(stdout)
    }

    if let message = HookClient.buildMessage(event: event, agent: normalizedAgent, input: input) {
        _ = HookClient.send(message)
    }
}

func runSetup(_ arguments: [String]) throws {
    guard arguments.count >= 2 else { throw CommandParseError.missingArgument("agent or all") }
    let target = arguments[1].lowercased()
    let force = arguments.contains("--force")
    let scope: HookInstallScope
    if let projectIndex = arguments.firstIndex(of: "--project") {
        let path = projectIndex + 1 < arguments.count && !arguments[projectIndex + 1].hasPrefix("-")
            ? arguments[projectIndex + 1]
            : FileManager.default.currentDirectoryPath
        scope = .project(URL(fileURLWithPath: path, isDirectory: true))
    } else if arguments.contains("--local") {
        scope = .local(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    } else {
        scope = .global
    }

    let agents: [SupportedAgent]
    if target == "all" {
        agents = SupportedAgent.allCases.filter { force || HookInstaller.isInstalled($0) }
    } else if let agent = SupportedAgent(rawValue: target) {
        agents = [agent]
    } else {
        throw CommandParseError.invalidValue(target)
    }
    if agents.isEmpty {
        print("No supported AI agent installations were detected. Add --force to generate all hook configurations.")
        return
    }
    for agent in agents {
        do {
            let result = try HookInstaller.install(agent: agent, scope: scope, executableURL: executableURL())
            print("Installed \(agent.rawValue) hooks: \(result.destination.path)")
        } catch HookInstallerError.unsupportedProjectScope {
            print("Skipped \(agent.rawValue): project-scoped hooks are not supported by this agent.")
        }
    }
}

private final class CompletedEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PromLightDaemonEvent?

    func set(_ event: PromLightDaemonEvent) {
        lock.lock()
        stored = event
        lock.unlock()
    }

    var value: PromLightDaemonEvent? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

func submitAndWait(_ message: HookMessage, to daemon: PromLightDaemon, timeout: TimeInterval = 10) -> PromLightDaemonEvent? {
    let semaphore = DispatchSemaphore(value: 0)
    let box = CompletedEventBox()
    daemon.submit(message) { event in
        box.set(event)
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
    return box.value
}

func inferredLightState(from events: [PromLightDaemonEvent]) -> String {
    guard let command = events.last(where: { $0.success && !$0.command.isEmpty })?.command else {
        return "Unknown"
    }
    return LightStateDescription.infer(from: command) ?? command.lowercased()
}

func runService(openBrowser: Bool) throws -> Never {
    try BootstrapConfiguration.ensureDefaults()
    let configuration = try ApplicationConfiguration.load()
    if openBrowser && localPortIsOpen(configuration.hookPort) && localPortIsOpen(configuration.webPort) {
        openLocalConsole(port: configuration.webPort)
        exit(0)
    }
    let controller = LightController()
    let batteryMonitor = PromLightBatteryMonitor()
    let daemon = PromLightDaemon(
        controller: controller,
        port: configuration.hookPort,
        deviceSelectorProvider: { message in
            (try? DeviceConfiguration.load(from: ApplicationPaths.devices))?
                .resolvedRoute(cwd: message.cwd, agent: message.agent)
        }
    )

    let webConsole = WebConsoleServer(
        statusProvider: {
            let daemonEvents = daemon.events(limit: 50)
            let devices = (try? controller.devices()) ?? []
            batteryMonitor.updateConnectedDevices(devices)
            let device = devices.first
            let batteryLevel = device.flatMap {
                batteryMonitor.battery(
                    for: $0,
                    allowAnonymousFallback: devices.count == 1
                )?.level
            }
            let entries = daemonEvents.suffix(25).map { event in
                let source = event.agent.isEmpty ? "PromLight" : event.agent.capitalized
                let text = event.error ?? (event.message.isEmpty ? event.command : event.message)
                return WebConsoleLogEntry(
                    timestamp: event.timestamp,
                    source: source,
                    message: text,
                    kind: event.success ? .success : .error
                )
            }
            let activeAgent = daemonEvents.last(where: { !$0.agent.isEmpty })?.agent.capitalized
            let connected = device != nil
            let serviceMessage: String
            if connected {
                serviceMessage = "PromLight service is running on this Mac."
            } else {
                serviceMessage = "The service is running and waiting for a PromLight device."
            }
            return WebConsoleStatus(
                connected: connected,
                deviceName: device?.product,
                serialNumber: device?.serialNumber,
                batteryLevel: batteryLevel,
                lightState: inferredLightState(from: daemonEvents),
                serviceMessage: serviceMessage,
                activeAgent: activeAgent,
                recentEvents: entries
            )
        },
        onCommand: { command in
            let message = HookMessage(
                cmd: command,
                message: "Manual console command",
                session: nil,
                cwd: nil,
                agent: "console",
                releaseSession: false,
                notice: ""
            )
            guard let event = submitAndWait(message, to: daemon) else {
                return WebConsoleActionResult(accepted: false, message: "The command timed out.")
            }
            return WebConsoleActionResult(
                accepted: event.success,
                message: event.success ? "Command completed." : (event.error ?? "The command failed.")
            )
        },
        onEvent: { event in
            let name = event.name ?? "WebEvent"
            let command = event.command ?? (try? EventConfiguration.load(from: ApplicationPaths.events).command(for: name)) ?? ""
            guard !command.isEmpty else {
                return WebConsoleActionResult(accepted: false, message: "No light command is mapped to this event.")
            }
            let message = HookMessage(
                cmd: command,
                message: event.message ?? name,
                session: event.session,
                cwd: event.cwd,
                agent: event.agent ?? "web",
                releaseSession: HookClient.sessionEndEvents.contains(name),
                notice: ""
            )
            guard let result = submitAndWait(message, to: daemon) else {
                return WebConsoleActionResult(accepted: false, message: "The event timed out.")
            }
            return WebConsoleActionResult(
                accepted: result.success,
                message: result.success ? "Event accepted." : (result.error ?? "The event failed.")
            )
        },
        port: configuration.webPort,
        stateHandler: { state in
            switch state {
            case .failed(let message): fputs("PromLight web console: \(message)\n", stderr)
            default: break
            }
        }
    )

    try daemon.start()
    do {
        try webConsole.start()
    } catch {
        daemon.stop()
        throw error
    }

    for _ in 0..<50 {
        if case .ready = daemon.status.lifecycle, case .ready = webConsole.state { break }
        if case .failed = daemon.status.lifecycle { break }
        if case .failed = webConsole.state { break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    if daemon.status.lifecycle == .failed {
        webConsole.stop()
        throw NSError(domain: "PromLight", code: 1, userInfo: [NSLocalizedDescriptionKey: daemon.status.lastError ?? "The hook listener failed to start."])
    }
    if case .failed(let message) = webConsole.state {
        daemon.stop()
        throw NSError(domain: "PromLight", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    if openBrowser {
        _ = try? ServiceInstaller.enable(executableURL: executableURL())
        openLocalConsole(port: configuration.webPort)
    }

    print("PromLight service: \(PromLightDaemon.host):\(configuration.hookPort)")
    print("English console: \(webConsole.consoleURL.absoluteString)")

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let stop: @Sendable () -> Void = {
        webConsole.stop()
        daemon.stop()
        exit(0)
    }
    termination.setEventHandler(handler: stop)
    interrupt.setEventHandler(handler: stop)
    termination.resume()
    interrupt.resume()
    dispatchMain()
}

switch arguments.first {
case "--version":
    print(version)
case "devices":
    do {
        let devices = try IOKitHIDTransport().enumerate()
        if devices.isEmpty {
            print("No connected PromLight devices were found.")
        } else {
            print("Connected PromLight devices: \(devices.count)")
            for device in devices {
                let firmware = String(
                    format: "v%d.%d.%d",
                    (device.versionNumber >> 8) & 0xFF,
                    (device.versionNumber >> 4) & 0x0F,
                    device.versionNumber & 0x0F
                )
                print("  \(device.product)  serial=\(device.serialNumber)  firmware=\(firmware)  VID=\(String(format: "%04X", device.vendorID)) PID=\(String(format: "%04X", device.productID))")
            }
        }
    } catch {
        fputs("PromLight: \(error)\n", stderr)
        exit(1)
    }
case "battery":
    do {
        let devices = try IOKitHIDTransport().enumerate()
        guard !devices.isEmpty else { throw LightControllerError.deviceNotFound(nil) }
        let readings = PromLightBatteryReader.readAll()
        var reported = false
        for device in devices {
            guard let battery = PromLightBatteryReader.battery(
                for: device,
                in: readings,
                allowAnonymousFallback: devices.count == 1
            ) else { continue }
            reported = true
            print("PromLight battery: \(battery.level)%  serial=\(device.serialNumber)")
        }
        if !reported {
            fputs("PromLight battery level is unavailable. Keep the device powered on and connected.\n", stderr)
            exit(1)
        }
    } catch {
        fputs("PromLight: \(error)\n", stderr)
        exit(1)
    }
case "test":
    do {
        let controller = LightController()
        let devices = try controller.devices()
        guard !devices.isEmpty else { throw LightControllerError.deviceNotFound(nil) }
        for device in devices {
            try controller.execute(
                script: "led yellow blink --only --count 2 --freq 500ms ; wait 1s ; led green on --only",
                deviceSelector: device.serialNumber
            )
            print("Hardware test passed: \(device.product) \(device.serialNumber)")
        }
    } catch {
        fputs("PromLight: \(error)\n", stderr)
        exit(1)
    }
case "command":
    guard arguments.count >= 2 else {
        fputs("PromLight: command requires a script\n", stderr)
        exit(2)
    }
    do {
        try LightController().execute(script: arguments.dropFirst().joined(separator: " "))
    } catch {
        fputs("PromLight: \(error)\n", stderr)
        exit(1)
    }
case "read":
    guard arguments.count == 2 else {
        fputs("PromLight: read requires one parameter\n", stderr)
        exit(2)
    }
    do {
        let results = try LightController().execute(script: "read \(arguments[1])")
        guard let value = results.first?.value else { throw AtomicProtocolError.invalidResponsePayload }
        print("\(arguments[1])=\(value)")
    } catch {
        fputs("PromLight: \(error)\n", stderr)
        exit(1)
    }
case "hook":
    runHook(arguments)
    exit(0)
case "setup":
    do {
        try runSetup(arguments)
    } catch {
        fputs("PromLight: \(error)\n", stderr)
        exit(2)
    }
case "autostart":
    let action = arguments.count > 1 ? arguments[1] : "status"
    do {
        switch action {
        case "enable":
            let destination = try ServiceInstaller.enable(executableURL: executableURL())
            let hookPort = (try? ApplicationConfiguration.load().hookPort) ?? PromLightDaemon.port
            if !localPortIsOpen(hookPort) { try ServiceInstaller.load() }
            print("PromLight will start at login: \(destination.path)")
        case "disable":
            try ServiceInstaller.disable()
            print("PromLight login startup is disabled.")
        case "status":
            print(ServiceInstaller.isEnabled ? "PromLight login startup is enabled." : "PromLight login startup is disabled.")
        default:
            throw CommandParseError.invalidValue(action)
        }
    } catch {
        fputs("PromLight: \(error)\n", stderr)
        exit(1)
    }
case "--selftest":
    do {
        let vector = try DeviceProtocol.request(for: .light(LightCommand(channels: .green, action: .on)))?.encoded
        guard vector == [0x5E, 0x5E, 0x04, 0x04, 0x01, 0x01, 0x00] else {
            throw AtomicProtocolError.invalidChecksum
        }
        let controller = LightController()
        let devices = try controller.devices()
        let batteries = PromLightBatteryReader.readAll()
        print("Protocol self-test: passed")
        if devices.isEmpty {
            print("Hardware self-test: skipped (no PromLight connected)")
        }
        for device in devices {
            print("Hardware: \(device.product) \(device.serialNumber)")
            if let battery = PromLightBatteryReader.battery(
                for: device,
                in: batteries,
                allowAnonymousFallback: devices.count == 1
            ) {
                print("  battery=\(battery.level)%")
            } else {
                print("  battery=unavailable")
            }
            for parameter in PersistentParameter.allCases {
                let result = try controller.execute(script: "read \(parameter.rawValue)", deviceSelector: device.serialNumber)
                print("  \(parameter.rawValue)=\(result.first?.value ?? -1)")
            }
        }
    } catch {
        fputs("PromLight self-test failed: \(error)\n", stderr)
        exit(1)
    }
case "--diag-open":
    do {
        let controller = LightController()
        let devices = try controller.devices()
        guard !devices.isEmpty else { throw LightControllerError.deviceNotFound(nil) }
        for device in devices {
            let result = try controller.execute(script: "read led.brightness", deviceSelector: device.serialNumber)
            print("Native non-exclusive HID open passed: \(device.serialNumber), brightness=\(result.first?.value ?? -1)%")
        }
    } catch {
        fputs("PromLight HID diagnostic failed: \(error)\n", stderr)
        exit(1)
    }
case nil:
    do {
        try runService(openBrowser: true)
    } catch {
        fputs("PromLight service failed: \(error)\n", stderr)
        exit(1)
    }
case "--headless", "--gui":
    do {
        try runService(openBrowser: false)
    } catch {
        fputs("PromLight service failed: \(error)\n", stderr)
        exit(1)
    }
case "--help", "-h", "help":
    printHelp()
default:
    fputs("PromLight: command not implemented yet: \(arguments[0])\n", stderr)
    exit(2)
}
