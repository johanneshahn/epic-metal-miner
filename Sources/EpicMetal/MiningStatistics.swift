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
    print("Mining statistics self-test: PASS")
}
