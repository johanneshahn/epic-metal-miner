import Foundation

/// Pure accounting for measured mining work. Time values are supplied by the
/// caller from a monotonic source; this keeps the formulas deterministic and
/// independently testable.
struct MiningPerformance {
    private(set) var hashes: UInt64 = 0
    private(set) var activeSeconds = 0.0
    private(set) var preparationSeconds = 0.0
    private(set) var reconnectSeconds = 0.0

    mutating func recordHashBatch(hashes: UInt64, activeSeconds: TimeInterval) {
        self.hashes &+= hashes
        self.activeSeconds += max(0, activeSeconds)
    }

    mutating func recordPreparation(_ seconds: TimeInterval) {
        preparationSeconds += max(0, seconds)
    }

    mutating func recordReconnect(_ seconds: TimeInterval) {
        reconnectSeconds += max(0, seconds)
    }

    func snapshot(sessionSeconds: TimeInterval) -> MiningPerformanceSnapshot {
        let elapsed = max(0, sessionSeconds)
        let idle = max(0, elapsed - activeSeconds - preparationSeconds - reconnectSeconds)
        return MiningPerformanceSnapshot(
            totalHashes: hashes,
            sessionSeconds: elapsed,
            activeSeconds: activeSeconds,
            preparationSeconds: preparationSeconds,
            reconnectSeconds: reconnectSeconds,
            algorithmIdleSeconds: idle
        )
    }
}

struct MiningPerformanceSnapshot {
    let totalHashes: UInt64
    let sessionSeconds: TimeInterval
    let activeSeconds: TimeInterval
    let preparationSeconds: TimeInterval
    let reconnectSeconds: TimeInterval
    let algorithmIdleSeconds: TimeInterval

    var activeMHps: Double { activeSeconds > 0 ? Double(totalHashes) / activeSeconds / 1e6 : 0 }
    var effectiveMHps: Double { sessionSeconds > 0 ? Double(totalHashes) / sessionSeconds / 1e6 : 0 }
    var activeUtilization: Double { sessionSeconds > 0 ? activeSeconds / sessionSeconds : 0 }
}

/// A recent active-only window, intentionally separate from session-cumulative
/// values. Its rate must not be multiplied by cumulative utilization.
struct MiningRateWindow {
    var hashes: UInt64 = 0
    var activeSeconds = 0.0

    mutating func record(hashes: UInt64, activeSeconds: TimeInterval) {
        self.hashes &+= hashes
        self.activeSeconds += max(0, activeSeconds)
    }

    var activeMHps: Double { activeSeconds > 0 ? Double(hashes) / activeSeconds / 1e6 : 0 }
}

/// Counts consensus-selected ProgPow heights, not job-template refreshes.
struct ProgpowBlockTracker {
    private(set) var count = 0
    private var lastHeight: UInt64?

    mutating func observe(height: UInt64) -> Bool {
        guard lastHeight != height else { return false }
        lastHeight = height
        count += 1
        return true
    }
}

/// Session-only share accounting. Jobs and blocks currently in progress are
/// deliberately included in averages; this is stated in the dashboard/docs.
struct ProgpowShareAccounting {
    private(set) var jobs = 0
    private(set) var blocks = 0
    private(set) var foundShares = 0
    private(set) var expectedShares = 0.0
    private var lastBlockHeight: UInt64?

    mutating func observeJob(height: UInt64) {
        jobs += 1
        if lastBlockHeight != height {
            blocks += 1
            lastBlockHeight = height
        }
    }

    mutating func recordHashes(_ hashes: UInt64, difficulty: UInt64) {
        guard difficulty > 0 else { return }
        // Epic accepts H <= floor((2^256 - 1) / D). For a uniform 256-bit
        // hash, p = (floor((2^256 - 1)/D) + 1) / 2^256, which is 1/D to
        // Double precision. Sum each job separately when difficulty changes.
        expectedShares += Double(hashes) / Double(difficulty)
    }

    mutating func recordFoundShare() { foundShares += 1 }

    var foundPerJob: Double { jobs > 0 ? Double(foundShares) / Double(jobs) : 0 }
    var foundPerBlock: Double { blocks > 0 ? Double(foundShares) / Double(blocks) : 0 }
    var expectedPerBlock: Double { blocks > 0 ? expectedShares / Double(blocks) : 0 }
}

/// Deterministic regression checks for active/effective accounting across
/// startup preparation, algorithm idle, reconnect delay and shutdown.
func runMiningStatisticsSelfTest() throws {
    var stats = MiningPerformance()
    stats.recordPreparation(10)
    stats.recordHashBatch(hashes: 264_000_000, activeSeconds: 20)
    stats.recordReconnect(5)
    let result = stats.snapshot(sessionSeconds: 60)
    guard result.totalHashes == 264_000_000,
          result.activeSeconds == 20,
          result.preparationSeconds == 10,
          result.reconnectSeconds == 5,
          result.algorithmIdleSeconds == 25,
          abs(result.activeMHps - 13.2) < 0.0001,
          abs(result.effectiveMHps - 4.4) < 0.0001,
          abs(result.activeUtilization - (1.0 / 3.0)) < 0.0001 else {
        throw EpicMiningError.malformedMessage("mining performance accounting regression")
    }

    // Reproduces the reported dashboard situation: a recent 13.10 MH/s
    // interval alongside a cumulative 5.00 MH/s session. They differ because
    // the session's cumulative active rate is 10.85 MH/s, not 13.10 MH/s.
    var recent = MiningRateWindow()
    recent.record(hashes: 131_000_000, activeSeconds: 10)
    var mixed = MiningPerformance()
    mixed.recordHashBatch(hashes: 500_000_000, activeSeconds: 46.1)
    let mixedResult = mixed.snapshot(sessionSeconds: 100)
    guard abs(recent.activeMHps - 13.1) < 0.0001,
          abs(mixedResult.activeMHps - 10.846) < 0.001,
          abs(mixedResult.effectiveMHps - 5.0) < 0.0001,
          abs(mixedResult.activeUtilization - 0.461) < 0.0001,
          abs(mixedResult.activeMHps * mixedResult.activeUtilization - mixedResult.effectiveMHps) < 0.0001 else {
        throw EpicMiningError.malformedMessage("mixed-window mining rate regression")
    }

    var blocks = ProgpowBlockTracker()
    guard blocks.observe(height: 100), !blocks.observe(height: 100),
          blocks.observe(height: 101), blocks.count == 2 else {
        throw EpicMiningError.malformedMessage("ProgPow block/template refresh regression")
    }
    var shares = ProgpowShareAccounting()
    shares.observeJob(height: 100) // partially observed block/job included
    shares.recordHashes(200_000_000, difficulty: 100_000_000)
    shares.recordFoundShare()
    shares.observeJob(height: 100)
    shares.recordHashes(100_000_000, difficulty: 50_000_000)
    shares.recordFoundShare()
    shares.observeJob(height: 101)
    guard shares.jobs == 3, shares.blocks == 2, shares.foundShares == 2,
          abs(shares.expectedShares - 4) < 0.0001,
          abs(shares.foundPerJob - (2.0 / 3.0)) < 0.0001,
          abs(shares.foundPerBlock - 1) < 0.0001,
          abs(shares.expectedPerBlock - 2) < 0.0001 else {
        throw EpicMiningError.malformedMessage("share expectation/accounting regression")
    }
    print("Mining statistics self-test: PASS")
}
