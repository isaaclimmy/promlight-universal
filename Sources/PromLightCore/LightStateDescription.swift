import Foundation

public enum LightStateDescription {
    public static func infer(from script: String) -> String? {
        guard let instructions = try? NorthboundCompiler.compileScript(script),
              let command = instructions.reversed().compactMap(lightCommand).first else {
            return nil
        }
        return describe(command)
    }

    private static func lightCommand(from instruction: DeviceInstruction) -> LightCommand? {
        guard case .light(let command) = instruction else { return nil }
        return command
    }

    private static func describe(_ command: LightCommand) -> String {
        if command.channels == .all {
            switch command.action {
            case .on: return "All lights on"
            case .off: return "Off"
            case .blink: return "All lights blinking"
            }
        }

        var channelNames = [
            (LightChannels.red, "red"),
            (LightChannels.yellow, "yellow"),
            (LightChannels.green, "green"),
        ].compactMap { channel, name in
            command.channels.contains(channel) ? name : nil
        }
        if !channelNames.isEmpty {
            channelNames[0] = channelNames[0].capitalized
        }
        let subject = joinedNames(channelNames)

        switch command.action {
        case .on:
            return channelNames.count == 1 ? subject : "\(subject) on"
        case .off:
            return "\(subject) off"
        case .blink:
            return "\(subject) blinking"
        }
    }

    private static func joinedNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Lights"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return "\(names.dropLast().joined(separator: ", ")), and \(names.last!)"
        }
    }
}
