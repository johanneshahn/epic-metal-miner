import Darwin
import Foundation

enum EpicColorMode: String {
    case auto, always, never
}

enum EpicDashboardMode: String {
    case compact, detailed
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
    private var dashboardLines = 0
    private var cursorHidden = false
    private var logHandle: FileHandle?
    private var recent = [String]()

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
    var columns: Int {
        var size = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
    }
    var recentActivity: [String] { recent }

    func event(_ level: MinerEventLevel, subsystem: String, _ message: String, console: Bool = true) {
        let plain = "\(timestamp()) \(level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(subsystem.padding(toLength: 8, withPad: " ", startingAt: 0)) \(message)"
        if let data = (plain + "\n").data(using: .utf8) { try? logHandle?.write(contentsOf: data) }
        let shortTime = String(timestamp().suffix(8))
        let symbol: String = level == .error ? "✕" : level == .warn ? "●" : "✓"
        recent.append("\(shortTime)  \(symbol) \(message)")
        if recent.count > 4 { recent.removeFirst(recent.count - 4) }
        guard console, !interactive else { return }
        print(colorize(level, plain))
    }

    func dashboard(_ text: String) {
        guard interactive else { return }
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let moveUp = dashboardDrawn ? "\u{001B}[\(dashboardLines)F" : ""
        let hide = cursorHidden ? "" : "\u{001B}[?25l"
        // Redraw only the dashboard region. No full-screen clear is used.
        print("\(hide)\(moveUp)\u{001B}[J\(decorateDashboard(text))", terminator: "")
        dashboardDrawn = true
        dashboardLines = lineCount
        cursorHidden = true
    }

    func finish() {
        if dashboardDrawn { print("") }
        if cursorHidden { print("\u{001B}[?25h", terminator: "") }
        try? logHandle?.close()
        logHandle = nil
    }

    private func colorize(_ level: MinerEventLevel, _ text: String) -> String {
        guard colors else { return text }
        let code: String
        switch level {
        case .error: code = "91" // bright red
        case .warn: code = "93"  // bright amber
        case .info: code = "92"  // bright green
        case .debug: code = "96" // bright cyan
        }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    private func decorateDashboard(_ text: String) -> String {
        guard colors else { return text }
        func paint(_ value: String, _ code: String) -> String { "\u{001B}[\(code)m\(value)\u{001B}[0m" }
        return text
            .replacingOccurrences(of: "EPIC METAL MINER", with: paint("EPIC METAL MINER", "96"))
            .replacingOccurrences(of: "MINING", with: paint("MINING", "92"))
            .replacingOccurrences(of: "WAITING", with: paint("WAITING", "93"))
            .replacingOccurrences(of: "Connected", with: paint("Connected", "92"))
            .replacingOccurrences(of: "Disconnected", with: paint("Disconnected", "91"))
            .replacingOccurrences(of: "ProgPow", with: paint("ProgPow", "97"))
            .replacingOccurrences(of: "PERFORMANCE", with: paint("PERFORMANCE", "96"))
            .replacingOccurrences(of: "NETWORK", with: paint("NETWORK", "96"))
            .replacingOccurrences(of: "SHARES", with: paint("SHARES", "96"))
            .replacingOccurrences(of: "RECENT ACTIVITY", with: paint("RECENT ACTIVITY", "96"))
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}

func compactDashboard(connection: Bool, algorithm: String, height: UInt64?, epoch: UInt64?, uptime: TimeInterval,
                      recentActiveMHps: Double, cumulativeActiveMHps: Double, effectiveMHps: Double,
                      power: Double?, efficiency: Double?, memoryBytes: UInt64?,
                      snapshot: MiningPerformanceSnapshot, stats: EpicMiningStats, jobShares: EpicJobShareStats?,
                      lastCompletedJob: String, acceptedPerProgpowBlock: Double,
                      foundPerProgpowBlock: Double, lastEvent: String, recentEvents: [String],
                      mode: EpicDashboardMode, narrow: Bool) -> String {
    let powerText = power.map { String(format: "%.1f W", $0) } ?? "unavailable"
    let efficiencyText = efficiency.map { String(format: "%.2f MH/s/W", $0) } ?? "unavailable"
    let memoryText = memoryBytes.map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "unavailable"
    let state = algorithm == "ProgPow" ? "● MINING" : "● WAITING — \(algorithm) block"
    let activity = recentEvents.isEmpty ? "  —" : recentEvents.map { "  \($0)" }.joined(separator: "\n")
    if narrow {
        return """
        EPIC METAL MINER  \(state)
        \(String(format: "%.2f MH/s", recentActiveMHps))  ACTIVE (RECENT)
        Effective \(String(format: "%.2f MH/s", effectiveMHps))  ·  \(String(format: "%.1f%%", snapshot.activeUtilization * 100)) ProgPow
        Shares \(stats.accepted) accepted / \(stats.rejected) rejected / \(stats.stale) stale
        \(lastEvent)
        """
    }
    var text = """
      EPIC METAL MINER                                      \(state)
      Apple Silicon · Metal GPU
      ───────────────────────────────────────────────────────────

                   \(String(format: "%.2f MH/s", recentActiveMHps))
                   ACTIVE HASHRATE (RECENT)

      Effective session  \(String(format: "%.2f MH/s", effectiveMHps))
      Active average     \(String(format: "%.2f MH/s", cumulativeActiveMHps))
      GPU power          \(powerText)
      Efficiency         \(efficiencyText)
      ProgPow time       \(String(format: "%.1f%%", snapshot.activeUtilization * 100))

      ───────────────────────────────────────────────────────────

      NETWORK
      Connection         \(connection ? "Connected" : "Disconnected")
      Algorithm          \(algorithm)
      Block              \(height.map { "#\($0)" } ?? "—")
      Uptime             \(formatDuration(uptime))

      ───────────────────────────────────────────────────────────

      SHARES             \(stats.accepted) accepted   \(stats.rejected) rejected   \(stats.stale) stale

      ───────────────────────────────────────────────────────────

      RECENT ACTIVITY
      \(activity)
    """
    if mode == .detailed {
        text += """

          DETAILS
          Process RSS        \(memoryText)
          Epoch              \(epoch.map(String.init) ?? "—")
          Share difficulty   \(jobShares.map { "job \($0.jobID)" } ?? "—")
          Total hashes       \(snapshot.totalHashes)
          Active / idle      \(formatDuration(snapshot.activeSeconds)) / \(formatDuration(snapshot.algorithmIdleSeconds))
          Preparation        \(formatDuration(snapshot.preparationSeconds))
          Reconnect          \(formatDuration(snapshot.reconnectSeconds))
          ProgPow blocks     \(stats.progpowBlocks)
          Shares/block       accepted \(String(format: "%.2f", acceptedPerProgpowBlock)) · found \(String(format: "%.2f", foundPerProgpowBlock))
          This job           \(jobShares?.summary ?? "—")
          Previous job       \(lastCompletedJob)
        """
    }
    return text
}
