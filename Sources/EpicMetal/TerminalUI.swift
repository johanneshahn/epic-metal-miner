import Darwin
import Foundation

enum EpicColorMode: String {
    case auto, always, never
}

enum MinerEventLevel: String {
    case error = "ERROR", warn = "WARN", info = "INFO", debug = "DEBUG"
}

/// Keeps terminal decoration out of persistent logs. ANSI is disabled for
/// redirection by default and can be explicitly disabled with NO_COLOR.
final class MinerTerminal {
    private let interactive: Bool
    private let colors: Bool
    private var dashboardDrawn = false
    private var logHandle: FileHandle?

    init(colorMode: EpicColorMode, logFile: String?) throws {
        interactive = isatty(STDOUT_FILENO) != 0
        colors = colorMode == .always || (colorMode == .auto && interactive && ProcessInfo.processInfo.environment["NO_COLOR"] == nil)
        if let logFile {
            let url = URL(fileURLWithPath: logFile)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            logHandle = try FileHandle(forWritingTo: url)
            try logHandle?.seekToEnd()
        }
    }

    var isInteractive: Bool { interactive }

    func event(_ level: MinerEventLevel, subsystem: String, _ message: String, console: Bool = true) {
        let plain = "\(timestamp()) \(level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(subsystem.padding(toLength: 8, withPad: " ", startingAt: 0)) \(message)"
        if let data = (plain + "\n").data(using: .utf8) { try? logHandle?.write(contentsOf: data) }
        guard console, !interactive else { return }
        print(colorize(level, plain))
    }

    func dashboard(_ text: String) {
        guard interactive else { return }
        // Home + clear is robust against resize/narrow terminals; it does not
        // emit escapes when output is redirected.
        print("\u{001B}[H\u{001B}[2J\(decorateDashboard(text))", terminator: "")
        dashboardDrawn = true
    }

    func finish() {
        if dashboardDrawn { print("") }
        try? logHandle?.close()
        logHandle = nil
    }

    private func colorize(_ level: MinerEventLevel, _ text: String) -> String {
        guard colors else { return text }
        let code: String
        switch level {
        case .error: code = "31"
        case .warn: code = "33"
        case .info: code = "32"
        case .debug: code = "36"
        }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    private func decorateDashboard(_ text: String) -> String {
        guard colors else { return text }
        func paint(_ value: String, _ code: String) -> String { "\u{001B}[\(code)m\(value)\u{001B}[0m" }
        return text
            .replacingOccurrences(of: "Epic Metal Miner", with: paint("Epic Metal Miner", "36"))
            .replacingOccurrences(of: "LIVE", with: paint("LIVE", "32"))
            .replacingOccurrences(of: "Connected", with: paint("Connected", "32"))
            .replacingOccurrences(of: "Disconnected", with: paint("Disconnected", "31"))
            .replacingOccurrences(of: "ProgPow", with: paint("ProgPow", "34"))
            .replacingOccurrences(of: "PERFORMANCE", with: paint("PERFORMANCE", "36"))
            .replacingOccurrences(of: "MINING TIME", with: paint("MINING TIME", "36"))
            .replacingOccurrences(of: "SHARES", with: paint("SHARES", "36"))
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}

func compactDashboard(connection: Bool, algorithm: String, height: UInt64?, epoch: UInt64?, uptime: TimeInterval,
                      activeMHps: Double, effectiveMHps: Double, power: Double?, efficiency: Double?, memoryBytes: UInt64?,
                      snapshot: MiningPerformanceSnapshot, stats: EpicMiningStats, lastEvent: String) -> String {
    let powerText = power.map { String(format: "%.1f W", $0) } ?? "unavailable"
    let efficiencyText = efficiency.map { String(format: "%.2f MH/s/W", $0) } ?? "unavailable"
    let memoryText = memoryBytes.map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "unavailable"
    return """
    Epic Metal Miner                                      LIVE
    ------------------------------------------------------------
    Connection     \(connection ? "Connected" : "Disconnected")
    Algorithm      \(algorithm)
    Block height   \(height.map(String.init) ?? "—")
    Epoch          \(epoch.map(String.init) ?? "—")
    Uptime         \(formatDuration(uptime))

    PERFORMANCE
    Active         \(String(format: "%.2f MH/s", activeMHps))
    Effective      \(String(format: "%.2f MH/s", effectiveMHps))
    GPU power      \(powerText)  (GPU only)
    Efficiency     \(efficiencyText)
    Process RSS    \(memoryText)

    MINING TIME
    ProgPow active \(String(format: "%.1f%%", snapshot.activeUtilization * 100))
    Other/no work  \(formatDuration(snapshot.algorithmIdleSeconds))
    Preparation    \(formatDuration(snapshot.preparationSeconds))
    Reconnect      \(formatDuration(snapshot.reconnectSeconds))

    SHARES
    Accepted \(stats.accepted)   Rejected \(stats.rejected)   Stale \(stats.stale)   Unknown \(stats.unknown)
    Reconnects \(stats.reconnects)
    ------------------------------------------------------------
    Last event     \(lastEvent)
    """
}
