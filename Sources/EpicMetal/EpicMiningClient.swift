import Darwin
import Foundation
import Metal

enum EpicLogVerbosity: String {
    case quiet, normal, verbose
}

struct EpicMiningConfig {
    let endpoint: String
    let worker: String
    let password: String
    let submitShares: Bool
    /// nil means continuous submission. A cap is useful for authorized tests.
    let maximumShares: Int?
    let statisticsInterval: TimeInterval
    let duration: TimeInterval?
    let verbosity: EpicLogVerbosity
    let colorMode: EpicColorMode
    let dashboardMode: EpicDashboardMode
    let logFile: String?
}

private var epicShutdownRequested = false

struct EpicMiningStats {
    var gpuPrefilterHits = 0
    var locallyValidShares = 0
    var submitted = 0
    var accepted = 0
    var rejected = 0
    var stale = 0
    var unknown = 0
    var reconnects = 0
    /// Consensus-selected ProgPow heights observed this session. Template
    /// refreshes at the same height do not increment this value.
    var progpowBlocks = 0
}

struct EpicJobShareStats {
    let fingerprint: String
    let height: UInt64
    let jobID: UInt64
    var found = 0
    var submitted = 0
    var accepted = 0
    var rejected = 0
    var stale = 0

    var summary: String {
        "height=\(height) job=\(jobID) found=\(found) submitted=\(submitted) accepted=\(accepted) rejected=\(rejected) stale=\(stale)"
    }
}

private struct EpicPendingRPC {
    let method: String
    let jobFingerprint: String?
}

private enum EpicShareResponse {
    case accepted, rejected, stale
}

/// Single-device native Epic ProgPow miner. It never implements CPU mining:
/// final share checking compares the GPU-produced digest to the full boundary.
final class EpicMiningClient {
    private let config: EpicMiningConfig
    private let terminal: MinerTerminal
    private let socket = EpicStratumSocket()
    private var gpu: EpicGpuSearcher?
    private var active: EpicMiningJob?
    private var generation: UInt64 = 0
    private var nonce = UInt64.random(in: UInt64.min...UInt64.max)
    private var requestCounter: UInt64 = 0
    private var requestMethods = [String: EpicPendingRPC]()
    private var statusRequestOutstanding = false
    private var stats = EpicMiningStats()
    private var performance = MiningPerformance()
    private var pendingSubmissions = 0
    private var lastShareReport = -Double.infinity
    // Nonces need only be remembered for the active template. Once a template
    // is replaced, a submission for it is stale and is never retried.
    private var submittedNonces = Set<UInt64>()
    private var connected = false
    private var stopSources = [DispatchSourceSignal]()
    private var lastEvent = "Starting"
    private var displayedAlgorithm: String?
    private var displayedHeight: UInt64?
    private var progpowBlockTracker = ProgpowBlockTracker()
    private var activeJobShares: EpicJobShareStats?
    // Completed jobs are retained only while they have a response outstanding.
    private var completedJobsAwaitingResponses = [String: EpicJobShareStats]()
    private var lastCompletedJob = "No completed ProgPow job yet"

    init(device: MTLDevice, config: EpicMiningConfig) throws {
        self.config = config
        self.terminal = try MinerTerminal(colorMode: config.colorMode, logFile: config.logFile)
        self.gpu = EpicGpuSearcher(device: device)
    }

    deinit { shutdown() }

    func run() throws {
        installSignalHandlers()
        let started = monotonicNow()
        defer {
            shutdown()
            printFinalStats(started: started)
            terminal.finish()
        }

        while !shouldStop(started: started) {
            do {
                try connectAndRequestJob()
                try runConnected(started: started)
            } catch {
                if pendingSubmissions > 0 {
                    // Never retry an unanswered submit: the node may have
                    // accepted it just before the disconnect. Record it as
                    // unknown and let a capped test terminate safely.
                    stats.unknown += pendingSubmissions
                    log(.normal, "lost connection with \(pendingSubmissions) submission response(s) unknown; not retrying")
                    pendingSubmissions = 0
                }
                invalidateJob()
                socket.close()
                requestMethods.removeAll(keepingCapacity: false)
                statusRequestOutstanding = false
                completedJobsAwaitingResponses.removeAll(keepingCapacity: false)
                connected = false
                guard !shouldStop(started: started) else { break }
                stats.reconnects += 1
                log(.normal, "connection error: \(error); retrying in 5 seconds")
                let reconnectStarted = monotonicNow()
                waitInterruptibly(seconds: 5, started: started)
                performance.recordReconnect(monotonicNow() - reconnectStarted)
            }
        }
    }

    private func runConnected(started: TimeInterval) throws {
        var nextStatus = monotonicNow() + 30
        var nextStats = monotonicNow() + config.statisticsInterval
        var intervalHashes: UInt64 = 0
        var intervalActiveSeconds = 0.0
        var intervalStart = monotonicNow()
        let power = GpuPowerSampler()
        var previousEnergy = power?.gpuJoules()

        while !shouldStop(started: started) {
            try drainIncoming()
            if monotonicNow() >= nextStatus, !statusRequestOutstanding {
                try send(method: "status", params: nil)
                nextStatus = monotonicNow() + 30
            }
            guard let job = active, let gpu else {
                waitInterruptibly(seconds: 0.05, started: started)
                continue
            }

            let preparationStarted = monotonicNow()
            let preparation = try gpu.prepare(for: job)
            let preparationSeconds = monotonicNow() - preparationStarted
            if preparation.rebuiltDAG || preparation.compiledProgram {
                performance.recordPreparation(preparationSeconds)
            }
            let dispatchStarted = monotonicNow()
            let result = try gpu.search(job: job, baseNonce: nonce)
            let dispatchSeconds = monotonicNow() - dispatchStarted
            nonce = result.nextNonce
            performance.recordHashBatch(hashes: result.hashesCovered, activeSeconds: dispatchSeconds)
            intervalHashes &+= result.hashesCovered
            intervalActiveSeconds += dispatchSeconds

            // Process a replacement before candidate handling. A job that
            // arrived during dispatch invalidates this complete GPU batch.
            try drainIncoming()
            guard active?.generation == job.generation, active?.fingerprint == job.fingerprint else { continue }
            if let candidate = result.candidate {
                stats.gpuPrefilterHits += 1
                if candidate.passedFullShareTarget {
                    stats.locallyValidShares += 1
                    try handleLocallyValid(candidate, job: job)
                }
            }

            if monotonicNow() >= nextStats {
                let now = monotonicNow()
                let intervalSeconds = now - intervalStart
                let currentMH = intervalActiveSeconds > 0 ? Double(intervalHashes) / intervalActiveSeconds / 1e6 : 0
                let snapshot = performance.snapshot(sessionSeconds: now - started)
                let energy = power?.gpuJoules()
                let watts: Double? = {
                    guard let previousEnergy, let energy, intervalSeconds > 0, energy >= previousEnergy else { return nil }
                    return (energy - previousEnergy) / intervalSeconds
                }()
                previousEnergy = energy
                printStatistics(job: job, uptime: now - started, currentMH: currentMH,
                                snapshot: snapshot, intervalActiveSeconds: intervalActiveSeconds,
                                intervalSeconds: intervalSeconds, watts: watts)
                intervalStart = now
                intervalHashes = 0
                intervalActiveSeconds = 0
                nextStats = now + config.statisticsInterval
            }
        }
    }

    private func connectAndRequestJob() throws {
        try socket.connect(endpoint: config.endpoint)
        connected = true
        try send(method: "login", params: ["login": config.worker, "pass": config.password, "agent": "epic-metal/0.2"])
        try send(method: "getjobtemplate", params: ["algorithm": EpicAlgorithm.progpow.rawValue])
        event(.info, subsystem: "STRATUM", "Connected to endpoint")
    }

    private func send(method: String, params: Any?, jobFingerprint: String? = nil) throws {
        requestCounter &+= 1
        let id = "native-\(requestCounter)"
        requestMethods[id] = EpicPendingRPC(method: method, jobFingerprint: jobFingerprint)
        try socket.sendJSON(epicRPCRequest(id: id, method: method, params: params))
        if method == "status" { statusRequestOutstanding = true }
    }

    private func drainIncoming() throws {
        while socket.hasReadableLine() {
            let message = try socket.readJSONLine()
            if message["method"] as? String == "job", let params = message["params"] {
                try install(template: decodeEpicTemplate(params))
                continue
            }
            let id = message["id"].map { String(describing: $0) }
            let request = id.flatMap { requestMethods.removeValue(forKey: $0) }
            let requestMethod = request?.method
            if requestMethod == "status" { statusRequestOutstanding = false }
            if let result = message["result"] as? [String: Any], result["pre_pow"] != nil {
                try install(template: decodeEpicTemplate(result))
                continue
            }
            if let error = message["error"], !(error is NSNull) {
                let text = String(describing: error)
                if requestMethod == "submit" {
                    pendingSubmissions = max(0, pendingSubmissions - 1)
                    if text.localizedCaseInsensitiveContains("too late") {
                        stats.stale += 1
                        recordShareResponse(request?.jobFingerprint, outcome: .stale)
                    } else {
                        stats.rejected += 1
                        recordShareResponse(request?.jobFingerprint, outcome: .rejected)
                    }
                }
                event(requestMethod == "submit" ? .error : .warn, subsystem: "STRATUM", "\(requestMethod ?? "RPC") response: \(text)")
                continue
            }
            if requestMethod == "submit", let result = message["result"] {
                pendingSubmissions = max(0, pendingSubmissions - 1)
                stats.accepted += 1
                recordShareResponse(request?.jobFingerprint, outcome: .accepted)
                event(.info, subsystem: "SHARE", "Accepted | total=\(stats.accepted) response=\(result)")
            } else if requestMethod == "status" {
                log(.verbose, "server status: \(message["result"] ?? "missing")")
            }
        }
    }

    private func install(template: EpicJobTemplate) throws {
        finishActiveJob()
        invalidateJob()
        guard template.algorithm == EpicAlgorithm.progpow.rawValue else {
            if displayedAlgorithm != template.algorithm || displayedHeight != template.height {
                event(.warn, subsystem: "MINING", "Paused | algorithm=\(template.algorithm) height=\(template.height)")
                displayedAlgorithm = template.algorithm
                displayedHeight = template.height
            } else {
                log(.verbose, "job generation \(generation): \(template.algorithm) template refreshed")
            }
            return
        }
        let job = try EpicMiningJob(generation: generation, template: template)
        if progpowBlockTracker.observe(height: template.height) {
            stats.progpowBlocks += 1
        }
        active = job
        activeJobShares = EpicJobShareStats(fingerprint: job.fingerprint, height: template.height, jobID: template.jobID)
        nonce = UInt64.random(in: UInt64.min...UInt64.max)
        let shareDifficulty = try template.shareDifficulty(for: .progpow)
        if displayedAlgorithm != template.algorithm || displayedHeight != template.height {
            event(.info, subsystem: "MINING", "ProgPow started | height=\(template.height) epoch=\(job.epoch) share_diff=\(shareDifficulty)")
            displayedAlgorithm = template.algorithm
            displayedHeight = template.height
        } else {
            log(.verbose, "job generation \(generation): ProgPow template refreshed")
        }
    }

    private func invalidateJob() {
        generation &+= 1
        active = nil
        submittedNonces.removeAll(keepingCapacity: true)
    }

    private func finishActiveJob() {
        guard let jobShares = activeJobShares else { return }
        if jobShares.submitted > jobShares.accepted + jobShares.rejected + jobShares.stale {
            completedJobsAwaitingResponses[jobShares.fingerprint] = jobShares
        } else {
            lastCompletedJob = jobShares.summary
            if jobShares.found > 0 || config.verbosity == .verbose {
                event(.info, subsystem: "MINING", "ProgPow job completed | \(jobShares.summary)")
            }
        }
        activeJobShares = nil
    }

    private func recordShareResponse(_ fingerprint: String?, outcome: EpicShareResponse) {
        guard let fingerprint else { return }
        if activeJobShares?.fingerprint == fingerprint {
            apply(outcome, to: &activeJobShares)
            return
        }
        guard var completed = completedJobsAwaitingResponses[fingerprint] else { return }
        apply(outcome, to: &completed)
        if completed.submitted == completed.accepted + completed.rejected + completed.stale {
            completedJobsAwaitingResponses.removeValue(forKey: fingerprint)
            lastCompletedJob = completed.summary
            event(.info, subsystem: "MINING", "ProgPow job completed | \(completed.summary)")
        } else {
            completedJobsAwaitingResponses[fingerprint] = completed
        }
    }

    private func apply(_ outcome: EpicShareResponse, to job: inout EpicJobShareStats?) {
        switch outcome {
        case .accepted: job?.accepted += 1
        case .rejected: job?.rejected += 1
        case .stale: job?.stale += 1
        }
    }

    private func apply(_ outcome: EpicShareResponse, to job: inout EpicJobShareStats) {
        switch outcome {
        case .accepted: job.accepted += 1
        case .rejected: job.rejected += 1
        case .stale: job.stale += 1
        }
    }

    private func handleLocallyValid(_ candidate: EpicGpuCandidate, job: EpicMiningJob) throws {
        let mix = wordsToBytesLE(candidate.mixWords)
        if activeJobShares?.fingerprint == job.fingerprint { activeJobShares?.found += 1 }
        if monotonicNow() - lastShareReport >= 2 {
            log(.verbose, "locally valid GPU share nonce=\(candidate.nonce) mix=\(bytesToHex(mix))")
            lastShareReport = monotonicNow()
        }
        guard config.submitShares else { return }
        if let limit = config.maximumShares, stats.submitted >= limit { return }
        // The generation/fingerprint was checked immediately before this call;
        // this identity check also suppresses duplicate submissions after a
        // response/reconnect race.
        guard submittedNonces.insert(candidate.nonce).inserted else {
            log(.normal, "duplicate candidate suppressed")
            return
        }
        let params: [String: Any] = [
            "height": job.template.height,
            "job_id": job.template.jobID,
            "nonce": candidate.nonce,
            "pow": ["ProgPow": mix.map(Int.init)],
        ]
        try send(method: "submit", params: params, jobFingerprint: job.fingerprint)
        stats.submitted += 1
        if activeJobShares?.fingerprint == job.fingerprint { activeJobShares?.submitted += 1 }
        pendingSubmissions += 1
        log(.verbose, "submitted \(stats.submitted)\(config.maximumShares.map { "/\($0)" } ?? ""): height=\(job.template.height) job_id=\(job.template.jobID) nonce=\(candidate.nonce)")
    }

    private func shouldStop(started: TimeInterval) -> Bool {
        if epicShutdownRequested { return true }
        if let duration = config.duration, monotonicNow() - started >= duration { return true }
        if let limit = config.maximumShares, config.submitShares,
           stats.submitted >= limit, pendingSubmissions == 0 { return true }
        return false
    }

    private func waitInterruptibly(seconds: TimeInterval, started: TimeInterval) {
        let deadline = monotonicNow() + seconds
        while monotonicNow() < deadline && !shouldStop(started: started) {
            Thread.sleep(forTimeInterval: min(0.1, deadline - monotonicNow()))
        }
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for signalNumber in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { epicShutdownRequested = true }
            source.resume()
            stopSources.append(source)
        }
    }

    private func shutdown() {
        socket.close()
        active = nil
        gpu?.releaseResources()
        gpu = nil
        connected = false
    }

    private func printStatistics(job: EpicMiningJob, uptime: TimeInterval, currentMH: Double,
                                 snapshot: MiningPerformanceSnapshot, intervalActiveSeconds: TimeInterval,
                                 intervalSeconds: TimeInterval, watts: Double?) {
        let powerText = watts.map { String(format: "%.2f W", $0) } ?? "unavailable"
        let activeCoverage = intervalSeconds > 0 ? intervalActiveSeconds / intervalSeconds : 0
        let efficiencyText = watts.flatMap { $0 > 0 && activeCoverage >= 0.8 ? String(format: "%.2f MH/s/W", currentMH / $0) : nil } ?? "unavailable (idle/preparing)"
        let memoryBytes = sampleProcessResidentMemoryBytes()
        let memoryText = memoryBytes.map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "unavailable"
        let efficiency = watts.flatMap { $0 > 0 && activeCoverage >= 0.8 ? currentMH / $0 : nil }
        let acceptedPerBlock = stats.progpowBlocks > 0 ? Double(stats.accepted) / Double(stats.progpowBlocks) : 0
        let foundPerBlock = stats.progpowBlocks > 0 ? Double(stats.locallyValidShares) / Double(stats.progpowBlocks) : 0
        if terminal.isInteractive {
            terminal.dashboard(compactDashboard(connection: connected, algorithm: "ProgPow", height: job.template.height,
                                                epoch: job.epoch, uptime: uptime, recentActiveMHps: currentMH,
                                                cumulativeActiveMHps: snapshot.activeMHps,
                                                effectiveMHps: snapshot.effectiveMHps, power: watts, efficiency: efficiency,
                                                memoryBytes: memoryBytes, snapshot: snapshot, stats: stats,
                                                jobShares: activeJobShares, lastCompletedJob: lastCompletedJob,
                                                acceptedPerProgpowBlock: acceptedPerBlock,
                                                foundPerProgpowBlock: foundPerBlock, lastEvent: lastEvent,
                                                recentEvents: terminal.recentActivity, mode: config.dashboardMode,
                                                narrow: terminal.columns < 72))
            return
        }
        print(String(format: "[miner] status=%@ uptime=%@ height=%llu epoch=%llu algorithm=progpow share_diff=%llu active_recent=%.2f MH/s active_average=%.2f MH/s effective_session=%.2f MH/s active_time=%.1f%% idle=%.1fs prep=%.1fs reconnect=%.1fs gpu_power=%@ efficiency=%@ memory=%@ job_shares=%@ progpow_blocks=%d accepted_per_block=%.2f found_per_block=%.2f accepted=%d rejected=%d stale=%d unknown=%d reconnects=%d",
                     connected ? "connected" : "disconnected", formatDuration(uptime), job.template.height, job.epoch,
                     (try? job.template.shareDifficulty(for: .progpow)) ?? 0, currentMH, snapshot.activeMHps, snapshot.effectiveMHps,
                     snapshot.activeUtilization * 100, snapshot.algorithmIdleSeconds, snapshot.preparationSeconds,
                     snapshot.reconnectSeconds, powerText, efficiencyText, memoryText, activeJobShares?.summary ?? "none", stats.progpowBlocks, acceptedPerBlock, foundPerBlock, stats.accepted, stats.rejected,
                     stats.stale, stats.unknown, stats.reconnects))
    }

    private func printFinalStats(started: TimeInterval) {
        let snapshot = performance.snapshot(sessionSeconds: monotonicNow() - started)
        print(String(format: "[miner] stopped: uptime=%@ hashes=%llu active=%.2f MH/s effective=%.2f MH/s active_time=%.1f%% idle=%.1fs prep=%.1fs reconnect=%.1fs submitted=%d accepted=%d rejected=%d stale=%d unknown=%d reconnects=%d",
                     formatDuration(snapshot.sessionSeconds), snapshot.totalHashes, snapshot.activeMHps,
                     snapshot.effectiveMHps, snapshot.activeUtilization * 100, snapshot.algorithmIdleSeconds,
                     snapshot.preparationSeconds, snapshot.reconnectSeconds, stats.submitted, stats.accepted,
                     stats.rejected, stats.stale, stats.unknown, stats.reconnects))
    }

    private func event(_ level: MinerEventLevel, subsystem: String, _ text: String) {
        lastEvent = text
        terminal.event(level, subsystem: subsystem, text)
    }

    private func log(_ level: EpicLogVerbosity, _ text: String) {
        let rank: [EpicLogVerbosity: Int] = [.quiet: 0, .normal: 1, .verbose: 2]
        if (rank[config.verbosity] ?? 1) >= (rank[level] ?? 1) {
            terminal.event(level == .verbose ? .debug : .info, subsystem: "MINER", text)
        }
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
}

/// Monotonic process uptime; unlike wall-clock time it is unaffected by NTP,
/// sleep/wake clock correction, or a user changing the system clock.
private func monotonicNow() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}

/// Resident memory measured from the OS `ps` report; unavailable is reported
/// rather than estimated when the tool cannot be read.
private func sampleProcessResidentMemoryBytes() -> UInt64? {
    guard let output = runTool("/bin/ps", ["-o", "rss=", "-p", "\(getpid())"]),
          let kib = UInt64(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return kib * 1024
}
