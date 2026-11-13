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
}

private var epicShutdownRequested = false

struct EpicMiningStats {
    var hashes: UInt64 = 0
    var hashingSeconds = 0.0
    var gpuPrefilterHits = 0
    var locallyValidShares = 0
    var submitted = 0
    var accepted = 0
    var rejected = 0
    var stale = 0
    var unknown = 0
    var reconnects = 0
}

/// Single-device native Epic ProgPow miner. It never implements CPU mining:
/// final share checking compares the GPU-produced digest to the full boundary.
final class EpicMiningClient {
    private let config: EpicMiningConfig
    private let socket = EpicStratumSocket()
    private var gpu: EpicGpuSearcher?
    private var active: EpicMiningJob?
    private var generation: UInt64 = 0
    private var nonce = UInt64.random(in: UInt64.min...UInt64.max)
    private var requestCounter: UInt64 = 0
    private var requestMethods = [String: String]()
    private var stats = EpicMiningStats()
    private var pendingSubmissions = 0
    private var lastShareReport = Date.distantPast
    private var submittedCandidates = Set<String>()
    private var connected = false
    private var stopSources = [DispatchSourceSignal]()

    init(device: MTLDevice, config: EpicMiningConfig) {
        self.config = config
        self.gpu = EpicGpuSearcher(device: device)
    }

    deinit { shutdown() }

    func run() throws {
        installSignalHandlers()
        let started = Date()
        defer {
            shutdown()
            printFinalStats(started: started)
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
                connected = false
                guard !shouldStop(started: started) else { break }
                stats.reconnects += 1
                log(.normal, "connection error: \(error); retrying in 5 seconds")
                waitInterruptibly(seconds: 5, started: started)
            }
        }
    }

    private func runConnected(started: Date) throws {
        var nextStatus = Date().addingTimeInterval(30)
        var nextStats = Date().addingTimeInterval(config.statisticsInterval)
        var intervalHashes: UInt64 = 0
        var intervalStart = Date()
        let power = GpuPowerSampler()
        var previousEnergy = power?.gpuJoules()

        while !shouldStop(started: started) {
            try drainIncoming()
            if Date() >= nextStatus {
                try send(method: "status", params: nil)
                nextStatus = Date().addingTimeInterval(30)
            }
            guard let job = active, let gpu else {
                waitInterruptibly(seconds: 0.05, started: started)
                continue
            }

            let dispatchStarted = Date()
            let result = try gpu.search(job: job, baseNonce: nonce)
            let dispatchSeconds = Date().timeIntervalSince(dispatchStarted)
            nonce = result.nextNonce
            stats.hashes &+= result.hashesCovered
            stats.hashingSeconds += dispatchSeconds
            intervalHashes &+= result.hashesCovered

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

            if Date() >= nextStats {
                let now = Date()
                let intervalSeconds = now.timeIntervalSince(intervalStart)
                let currentMH = intervalSeconds > 0 ? Double(intervalHashes) / intervalSeconds / 1e6 : 0
                let averageMH = stats.hashingSeconds > 0 ? Double(stats.hashes) / stats.hashingSeconds / 1e6 : 0
                let energy = power?.gpuJoules()
                let watts: Double? = {
                    guard let previousEnergy, let energy, intervalSeconds > 0, energy >= previousEnergy else { return nil }
                    return (energy - previousEnergy) / intervalSeconds
                }()
                previousEnergy = energy
                printStatistics(job: job, uptime: now.timeIntervalSince(started), currentMH: currentMH,
                                averageMH: averageMH, watts: watts)
                intervalStart = now
                intervalHashes = 0
                nextStats = now.addingTimeInterval(config.statisticsInterval)
            }
        }
    }

    private func connectAndRequestJob() throws {
        try socket.connect(endpoint: config.endpoint)
        connected = true
        try send(method: "login", params: ["login": config.worker, "pass": config.password, "agent": "epic-metal/0.2"])
        try send(method: "getjobtemplate", params: ["algorithm": EpicAlgorithm.progpow.rawValue])
        log(.normal, "connected to \(config.endpoint); waiting for consensus-selected jobs")
    }

    private func send(method: String, params: Any?) throws {
        requestCounter &+= 1
        let id = "native-\(requestCounter)"
        requestMethods[id] = method
        try socket.sendJSON(epicRPCRequest(id: id, method: method, params: params))
    }

    private func drainIncoming() throws {
        while socket.hasReadableLine() {
            let message = try socket.readJSONLine()
            if message["method"] as? String == "job", let params = message["params"] {
                try install(template: decodeEpicTemplate(params))
                continue
            }
            let id = message["id"].map { String(describing: $0) }
            let requestMethod = id.flatMap { requestMethods.removeValue(forKey: $0) }
            if let result = message["result"] as? [String: Any], result["pre_pow"] != nil {
                try install(template: decodeEpicTemplate(result))
                continue
            }
            if let error = message["error"], !(error is NSNull) {
                let text = String(describing: error)
                if requestMethod == "submit" {
                    pendingSubmissions = max(0, pendingSubmissions - 1)
                    if text.localizedCaseInsensitiveContains("too late") { stats.stale += 1 }
                    else { stats.rejected += 1 }
                }
                log(.normal, "server response\(requestMethod.map { " for \($0)" } ?? ""): \(text)")
                continue
            }
            if requestMethod == "submit", let result = message["result"] {
                pendingSubmissions = max(0, pendingSubmissions - 1)
                stats.accepted += 1
                log(.normal, "server response (accepted): \(result)")
            } else if requestMethod == "status" {
                log(.verbose, "server status: \(message["result"] ?? "missing")")
            }
        }
    }

    private func install(template: EpicJobTemplate) throws {
        invalidateJob()
        guard template.algorithm == EpicAlgorithm.progpow.rawValue else {
            log(.normal, "job generation \(generation): \(template.algorithm) at height \(template.height); idle")
            return
        }
        let job = try EpicMiningJob(generation: generation, template: template)
        active = job
        nonce = UInt64.random(in: UInt64.min...UInt64.max)
        let shareDifficulty = try template.shareDifficulty(for: .progpow)
        log(.normal, "job generation \(generation): ProgPow height \(template.height), epoch \(job.epoch), share diff \(shareDifficulty)")
    }

    private func invalidateJob() {
        generation &+= 1
        active = nil
    }

    private func handleLocallyValid(_ candidate: EpicGpuCandidate, job: EpicMiningJob) throws {
        let mix = wordsToBytesLE(candidate.mixWords)
        if Date().timeIntervalSince(lastShareReport) >= 2 {
            log(.normal, "locally valid GPU share nonce=\(candidate.nonce) mix=\(bytesToHex(mix))")
            lastShareReport = Date()
        }
        guard config.submitShares else { return }
        if let limit = config.maximumShares, stats.submitted >= limit { return }
        // The generation/fingerprint was checked immediately before this call;
        // this identity check also suppresses duplicate submissions after a
        // response/reconnect race.
        let candidateKey = "\(job.fingerprint):\(candidate.nonce)"
        guard submittedCandidates.insert(candidateKey).inserted else {
            log(.normal, "duplicate candidate suppressed")
            return
        }
        let params: [String: Any] = [
            "height": job.template.height,
            "job_id": job.template.jobID,
            "nonce": candidate.nonce,
            "pow": ["ProgPow": mix.map(Int.init)],
        ]
        try send(method: "submit", params: params)
        stats.submitted += 1
        pendingSubmissions += 1
        log(.normal, "submitted \(stats.submitted)\(config.maximumShares.map { "/\($0)" } ?? ""): height=\(job.template.height) job_id=\(job.template.jobID) nonce=\(candidate.nonce)")
    }

    private func shouldStop(started: Date) -> Bool {
        if epicShutdownRequested { return true }
        if let duration = config.duration, Date().timeIntervalSince(started) >= duration { return true }
        if let limit = config.maximumShares, config.submitShares,
           stats.submitted >= limit, pendingSubmissions == 0 { return true }
        return false
    }

    private func waitInterruptibly(seconds: TimeInterval, started: Date) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !shouldStop(started: started) {
            Thread.sleep(forTimeInterval: min(0.1, deadline.timeIntervalSinceNow))
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

    private func printStatistics(job: EpicMiningJob, uptime: TimeInterval, currentMH: Double, averageMH: Double, watts: Double?) {
        let powerText = watts.map { String(format: "%.2f W", $0) } ?? "unavailable"
        let efficiencyText = watts.flatMap { $0 > 0 ? String(format: "%.2f MH/s/W", currentMH / $0) : nil } ?? "unavailable"
        let memoryText = sampleProcessResidentMemoryBytes().map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "unavailable"
        print(String(format: "[miner] status=%@ uptime=%@ height=%llu epoch=%llu algorithm=progpow share_diff=%llu current=%.2f MH/s avg=%.2f MH/s gpu_power=%@ efficiency=%@ memory=%@ accepted=%d rejected=%d stale=%d unknown=%d reconnects=%d",
                     connected ? "connected" : "disconnected", formatDuration(uptime), job.template.height, job.epoch,
                     (try? job.template.shareDifficulty(for: .progpow)) ?? 0, currentMH, averageMH,
                     powerText, efficiencyText, memoryText, stats.accepted, stats.rejected, stats.stale, stats.unknown, stats.reconnects))
    }

    private func printFinalStats(started: Date) {
        let uptime = Date().timeIntervalSince(started)
        let averageMH = stats.hashingSeconds > 0 ? Double(stats.hashes) / stats.hashingSeconds / 1e6 : 0
        print(String(format: "[miner] stopped: uptime=%@ hashes=%llu avg=%.2f MH/s submitted=%d accepted=%d rejected=%d stale=%d unknown=%d reconnects=%d",
                     formatDuration(uptime), stats.hashes, averageMH, stats.submitted, stats.accepted, stats.rejected, stats.stale, stats.unknown, stats.reconnects))
    }

    private func log(_ level: EpicLogVerbosity, _ text: String) {
        let rank: [EpicLogVerbosity: Int] = [.quiet: 0, .normal: 1, .verbose: 2]
        if (rank[config.verbosity] ?? 1) >= (rank[level] ?? 1) { print("[miner] \(text)") }
    }
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
}

/// Resident memory measured from the OS `ps` report; unavailable is reported
/// rather than estimated when the tool cannot be read.
private func sampleProcessResidentMemoryBytes() -> UInt64? {
    guard let output = runTool("/bin/ps", ["-o", "rss=", "-p", "\(getpid())"]),
          let kib = UInt64(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return kib * 1024
}
