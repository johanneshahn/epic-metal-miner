import Foundation
import Metal

// ===========================================================================
// Phase 3 — GPU hashing benchmark.
//
// Design notes:
//
// * The benchmark runs at a *real* mainnet height (default: the live tip), so
//   the DAG size, the epoch and the per-period generated program are the ones
//   the network is actually using. It is not a synthetic loop.
//
// * Before measuring, it re-verifies a known-answer vector produced by the Rust
//   reference at that exact height (`epic_live_vector.json`). A benchmark run
//   therefore cannot report a hashrate for an epoch whose hashing has not just
//   been shown to be correct.
//
// * `target` defaults to 0, i.e. no nonce ever "wins". With a real network
//   difficulty a share is found roughly once per (difficulty) hashes, so over a
//   ten-minute run we would expect zero wins anyway; using 0 keeps every
//   dispatch running to completion so the throughput number is not distorted by
//   the early-exit path. The comparison itself still executes.
//
// * Telemetry: GPU utilisation is read from the IOKit accelerator node via
//   `ioreg`; thermal pressure via `pmset -g therm`. Package power needs root
//   (`powermetrics`) and is reported as unavailable when it cannot be read.
// ===========================================================================

// ---------------------------------------------------------------------------
// Live-epoch known-answer vector
// ---------------------------------------------------------------------------

struct EpicLiveVector {
    let height: UInt64
    let epoch: UInt64
    let period: UInt64
    let headerHash: [UInt8]
    let nonce: UInt64
    let mixHash: [UInt8]
    let finalHash: [UInt8]
    let dagElements: UInt32
    let cdagFnv: UInt32
    let cdagRot: UInt32

    var headerWords: [UInt32] {
        (0..<8).map { u32FromLE(headerHash[($0 * 4)..<($0 * 4 + 4)]) }
    }
}

func loadEpicLiveVector() throws -> EpicLiveVector {
    guard let url = Bundle.module.url(forResource: "epic_live_vector", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw EpicKernelError.resourceMissing("epic_live_vector.json")
    }
    func hexU32(_ key: String) -> UInt32 { UInt32(row[key] as! String, radix: 16)! }
    return EpicLiveVector(
        height: UInt64(row["height"] as! Int),
        epoch: UInt64(row["epoch"] as! Int),
        period: UInt64(row["period"] as! Int),
        headerHash: hexToBytes(row["header_hash"] as! String),
        nonce: UInt64(row["nonce"] as! String, radix: 16)!,
        mixHash: hexToBytes(row["mix_hash"] as! String),
        finalHash: hexToBytes(row["final_hash"] as! String),
        dagElements: UInt32(row["dag_elements"] as! Int),
        cdagFnv: hexU32("cdag_fnv"),
        cdagRot: hexU32("cdag_rot")
    )
}

/// Re-verify the live-epoch vector on the GPU. Returns true when the GPU
/// reproduces the Rust reference's mix and final hash for the live epoch.
func checkEpicLiveVector(device: MTLDevice,
                         queue: MTLCommandQueue,
                         dag: DAGOutput,
                         pso: MTLComputePipelineState,
                         vector: EpicLiveVector) throws -> Bool {
    let dagElements = dag.dagNumItems / 4
    var ok = true

    if dagElements != vector.dagElements {
        print("  live vector: dag_elements got \(dagElements), reference \(vector.dagElements)  FAIL")
        ok = false
    } else {
        print("  live vector: dag_elements \(dagElements)  PASS")
    }

    // c_dag fingerprint (first 4096 words of the DAG) against the Rust oracle.
    let words = dag.dag.contents().assumingMemoryBound(to: UInt32.self)
    let fp = cdagFingerprint(UnsafeBufferPointer(start: words, count: 4096))
    if fp.fnv != vector.cdagFnv || fp.rotSum != vector.cdagRot {
        print(String(format: "  live vector: c_dag fnv=%08x rot=%08x, reference fnv=%08x rot=%08x  FAIL",
                     fp.fnv, fp.rotSum, vector.cdagFnv, vector.cdagRot))
        ok = false
    } else {
        print(String(format: "  live vector: c_dag fnv=%08x rot=%08x  PASS", fp.fnv, fp.rotSum))
    }

    let r = try runEpicProbe(device: device, queue: queue, pso: pso, dag: dag.dag,
                             dagElements: dagElements, headerWords: vector.headerWords, nonce: vector.nonce)
    let mixOK = wordsToBytesLE(r.mix) == vector.mixHash
    let finalOK = wordsToBytesLE(r.final) == vector.finalHash
    print("  live vector: mix=\(mixOK ? "PASS" : "FAIL") final=\(finalOK ? "PASS" : "FAIL")")
    if !mixOK {
        print("    expected mix   \(bytesToHex(vector.mixHash))")
        print("    got      mix   \(bytesToHex(wordsToBytesLE(r.mix)))")
    }
    if !finalOK {
        print("    expected final \(bytesToHex(vector.finalHash))")
        print("    got      final \(bytesToHex(wordsToBytesLE(r.final)))")
    }
    return ok && mixOK && finalOK
}

// ---------------------------------------------------------------------------
// Host telemetry
// ---------------------------------------------------------------------------

struct GpuUtilisation {
    let device: Int?
    let renderer: Int?
    let tiler: Int?
    var summary: String {
        func f(_ v: Int?) -> String { v.map { "\($0)%" } ?? "n/a" }
        return "device \(f(device)) renderer \(f(renderer)) tiler \(f(tiler))"
    }
}

/// Execute a macOS telemetry utility. Callers report unavailable telemetry
/// rather than deriving estimates when this cannot be read.
func runTool(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    // `Process` needs an absolute executable URL; relative paths are resolved
    // against the current working directory here.
    let absolute = path.hasPrefix("/")
        ? path
        : FileManager.default.currentDirectoryPath + "/" + path
    p.executableURL = URL(fileURLWithPath: absolute).standardizedFileURL
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

func sampleGpuUtilisation() -> GpuUtilisation? {
    guard let text = runTool("/usr/sbin/ioreg", ["-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"]) else { return nil }
    func value(_ key: String) -> Int? {
        guard let r = text.range(of: "\"\(key)\"") else { return nil }
        let rest = text[r.upperBound...]
        guard let eq = rest.firstIndex(of: "=") else { return nil }
        let digits = rest[rest.index(after: eq)...].drop(while: { $0 == " " }).prefix(while: { $0.isNumber })
        return Int(digits)
    }
    let u = GpuUtilisation(device: value("Device Utilization %"),
                           renderer: value("Renderer Utilization %"),
                           tiler: value("Tiler Utilization %"))
    return u.device == nil && u.renderer == nil ? nil : u
}

func sampleThermalPressure() -> String {
    guard let text = runTool("/usr/bin/pmset", ["-g", "therm"]) else { return "unavailable" }
    let interesting = text.split(separator: "\n")
        .filter { $0.contains("CPU_Scheduler_Limit") || $0.contains("CPU_Available_CPUs")
                  || $0.contains("CPU_Speed_Limit") || $0.contains("GPU_") || $0.contains("warning") }
        .joined(separator: " ")
    return interesting.isEmpty ? "no thermal warning recorded" : interesting
}

// ---------------------------------------------------------------------------
// GPU energy / power via IOReport (no root required)
// ---------------------------------------------------------------------------
//
// `powermetrics` refuses to run without root, but it is only a front-end for the
// IOReport "Energy Model" group, which is readable from userspace via the
// private libIOReport API. The "GPU Energy" channel is a monotonic counter in
// nanojoules, so GPU power over an interval is simply delta / interval. This is
// what makes the power figure in the benchmark output a measurement rather than
// an estimate.
final class GpuPowerSampler {
    private typealias SamplesFn = @convention(c) (CFTypeRef?, CFMutableDictionary?, CFTypeRef?) -> CFDictionary?
    private typealias StringFn  = @convention(c) (CFDictionary?) -> CFString?
    private typealias IntFn     = @convention(c) (CFDictionary?, Int32) -> Int64

    private let sub: CFTypeRef
    private let subbed: CFMutableDictionary?
    private let createSamples: SamplesFn
    private let getName: StringFn
    private let getUnit: StringFn
    private let getValue: IntFn
    private let channelName = "GPU Energy"

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        typealias CopyChannelsFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> CFMutableDictionary?
        typealias CreateSubFn = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?, UnsafeMutablePointer<CFMutableDictionary?>?, UInt64, CFTypeRef?) -> CFTypeRef?
        guard let copyChannels = sym("IOReportCopyChannelsInGroup", CopyChannelsFn.self),
              let createSub    = sym("IOReportCreateSubscription", CreateSubFn.self),
              let samplesFn    = sym("IOReportCreateSamples", SamplesFn.self),
              let nameFn       = sym("IOReportChannelGetChannelName", StringFn.self),
              let unitFn       = sym("IOReportChannelGetUnitLabel", StringFn.self),
              let valueFn      = sym("IOReportSimpleGetIntegerValue", IntFn.self),
              let channels     = copyChannels("Energy Model" as CFString, nil, 0, 0, 0) else { return nil }
        var subscribed: CFMutableDictionary?
        guard let subscription = createSub(nil, channels, &subscribed, 0, nil) else { return nil }
        self.sub = subscription
        self.subbed = subscribed
        self.createSamples = samplesFn
        self.getName = nameFn
        self.getUnit = unitFn
        self.getValue = valueFn
    }

    /// Cumulative GPU energy in joules, or nil when the channel is unavailable.
    func gpuJoules() -> Double? {
        guard let samples = createSamples(sub, subbed, nil) else { return nil }
        let count = CFDictionaryGetCount(samples)
        guard count > 0 else { return nil }
        let keys = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: count)
        let vals = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: count)
        defer { keys.deallocate(); vals.deallocate() }
        CFDictionaryGetKeysAndValues(samples, keys, vals)
        for i in 0..<count {
            guard let raw = vals[i] else { continue }
            let array = unsafeBitCast(raw, to: CFArray.self)
            for j in 0..<CFArrayGetCount(array) {
                let channel = unsafeBitCast(CFArrayGetValueAtIndex(array, j), to: CFDictionary.self)
                guard let name = getName(channel).map({ $0 as String }), name == channelName else { continue }
                let unit = getUnit(channel).map({ $0 as String }) ?? "nJ"
                let value = Double(getValue(channel, 0))
                switch unit {
                case "nJ": return value * 1e-9
                case "uJ": return value * 1e-6
                case "mJ": return value * 1e-3
                case "J":  return value
                default:   return nil
                }
            }
        }
        return nil
    }
}

// ---------------------------------------------------------------------------
// Mint a known-answer vector for an arbitrary height with the Rust oracle
// ---------------------------------------------------------------------------

/// Runs `oracle hash <height> <header> <nonce>` and parses its output. This lets
/// the benchmark validate itself at any height, not just the bundled one.
func mintLiveVector(oraclePath: String, height: UInt64, headerHex: String, nonceHex: String) -> EpicLiveVector? {
    guard let text = runTool(oraclePath, ["hash", "\(height)", headerHex, nonceHex]) else { return nil }
    var fields: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { continue }
        // Keep the whole remainder so multi-token values (the `cdag` line) survive.
        fields[String(parts[0])] = parts.dropFirst().joined(separator: " ")
    }
    guard let mix = fields["mix_hash_le"], let fin = fields["final_hash_le"],
          let de = fields["dag_elements"], let fnv = fields["cdag"] else { return nil }
    // "fnv1a=c8e4dede rot_sum=9a7d82d6 w0=... w1=..."
    let kv = fnv.split(separator: " ").reduce(into: [String: String]()) { acc, tok in
        let p = tok.split(separator: "=")
        if p.count == 2 { acc[String(p[0])] = String(p[1]) }
    }
    guard let fnvHex = kv["fnv1a"], let rotHex = kv["rot_sum"] else { return nil }
    return EpicLiveVector(
        height: height,
        epoch: height / Ethash.EPIC_EPOCH_LENGTH,
        period: height / UInt64(EpicProgPow.PROGPOW_PERIOD),
        headerHash: hexToBytes(headerHex),
        nonce: UInt64(nonceHex, radix: 16)!,
        mixHash: hexToBytes(mix),
        finalHash: hexToBytes(fin),
        dagElements: UInt32(de)!,
        cdagFnv: UInt32(fnvHex, radix: 16)!,
        cdagRot: UInt32(rotHex, radix: 16)!
    )
}

// ---------------------------------------------------------------------------
// Benchmark
// ---------------------------------------------------------------------------

struct EpicBenchConfig {
    var height: UInt64 = 3_795_484          // live Epic mainnet tip at time of writing
    var minutes: Double = 10
    var groups: UInt32 = 4096               // threadgroups per dispatch
    var threadsPerGroup: UInt32 = 256
    /// Command buffers allowed on the GPU simultaneously. Mining uses one
    /// synchronous dispatch; the default benchmark measures saturated GPU
    /// throughput with eight.
    var inflight: Int = 8
    var headerHex: String? = nil
    var targetHex: String? = nil
    var sampleSeconds: Double = 30
    var jsonOut: String? = nil
    var oraclePath: String? = nil           // auto-detected when nil
    var skipValidation = false
}

func runEpicBenchmark(device: MTLDevice, config: EpicBenchConfig) throws -> Int {
    let epoch = config.height / Ethash.EPIC_EPOCH_LENGTH
    let period = config.height / UInt64(EpicProgPow.PROGPOW_PERIOD)
    let queue = device.makeCommandQueue()!

    print("=== Epic Cash ProgPoW 0.9.2 — Metal GPU benchmark ===")
    print("device:        \(device.name)")
    print("height:        \(config.height)  (epoch \(epoch), prog_seed \(period))")
    print("duration:      \(config.minutes) min   sample every \(Int(config.sampleSeconds))s")
    print("dispatch:      \(config.groups) threadgroups x \(config.threadsPerGroup) threads = \(UInt64(config.groups) * UInt64(config.threadsPerGroup)) hashes")
    print("in flight:     \(config.inflight) command buffer\(config.inflight == 1 ? "" : "s")")

    // Header hash: explicit, else the live-vector header, else the known tip hash.
    let headerHex = config.headerHex
        ?? (try? loadEpicLiveVector())?.headerHash.hexString
        ?? "abf95d81edeb66ff175e8c1881d75eb426e5005e49decaa0ba9e0cbba9f0b8b6"
    let headerBytes = hexToBytes(headerHex)
    guard headerBytes.count == 32 else {
        FileHandle.standardError.write("header must be 32 bytes of hex\n".data(using: .utf8)!)
        return 2
    }
    let headerWords = (0..<8).map { u32FromLE(headerBytes[($0 * 4)..<($0 * 4 + 4)]) }

    var target: UInt64 = 0
    if let t = config.targetHex {
        let padded = String(repeating: "0", count: max(0, 64 - t.count)) + t
        target = UInt64(padded.prefix(16), radix: 16)!
    }
    print("header:        \(headerHex)")
    print("target:        \(String(format: "%016llx", target))\(target == 0 ? "  (0 = no nonce ever wins; see header comment)" : "")")

    // --- DAG -------------------------------------------------------------
    print("\n--- building epoch \(epoch) DAG ---")
    let dag = try buildDAG(device: device, epoch: epoch)
    let dagElements = dag.dagNumItems / 4

    // --- per-period program ---------------------------------------------
    let tCompile = Date()
    let pso = try compileEpicKernel(device: device, progSeed: period)
    print(String(format: "[kernel] compiled prog_seed %llu in %.2fs", period, Date().timeIntervalSince(tCompile)))

    // --- pre-flight correctness check ------------------------------------
    var validationNote = "skipped"
    if !config.skipValidation {
        print("\n--- pre-flight known-answer check at this exact epoch/period ---")
        var vec: EpicLiveVector? = nil
        let oracle = config.oraclePath ?? "../oracle/oracle/target/release/oracle"
        if FileManager.default.isExecutableFile(atPath: oracle) {
            vec = mintLiveVector(oraclePath: oracle, height: config.height, headerHex: headerHex, nonceHex: "0000000000000000")
            if vec != nil {
                validationNote = "oracle@\(config.height)"
            } else {
                print("  note: oracle at \(oracle) ran but produced no parseable vector; falling back")
            }
        } else {
            print("  note: no oracle binary at \(oracle); falling back to bundled vector")
        }
        if vec == nil, let bundled = try? loadEpicLiveVector(), bundled.height == config.height {
            vec = bundled
            validationNote = "bundled-vector@\(config.height)"
        }
        if let v = vec {
            let ok = try checkEpicLiveVector(device: device, queue: queue, dag: dag, pso: pso, vector: v)
            guard ok else {
                FileHandle.standardError.write("pre-flight validation FAILED — refusing to report a hashrate\n".data(using: .utf8)!)
                return 1
            }
            print("  pre-flight: PASS (\(validationNote))")
        } else {
            validationNote = "unavailable (no oracle, and bundled vector is for height \((try? loadEpicLiveVector())?.height ?? 0))"
            print("  WARNING: no known-answer vector available for this height; benchmark continues unvalidated")
        }
    }

    // --- buffers ---------------------------------------------------------
    let headerBuf  = device.makeBuffer(bytes: headerWords, length: 32, options: .storageModeShared)!
    let resultsBuf = device.makeBuffer(length: 64 * 4, options: .storageModeShared)!
    let indexBuf   = device.makeBuffer(length: 4, options: .storageModeShared)!
    let stopBuf    = device.makeBuffer(length: 4, options: .storageModeShared)!
    memset(resultsBuf.contents(), 0, 64 * 4)
    memset(indexBuf.contents(), 0, 4)
    memset(stopBuf.contents(), 0, 4)

    // The kernel fixes GROUP_SIZE at 256: `share[HASHES_PER_GROUP]`, the c_dag
    // preload stride and the `share[0].uint32s[group_id]` nonce transposition
    // all assume exactly 16 lane-groups. Any other threadgroup size yields
    // silently incorrect hashes (a smaller size leaves c_dag partly
    // uninitialised; a larger one overruns share[0]), so it is rejected here
    // rather than mis-measured.
    guard config.threadsPerGroup == 256 else {
        FileHandle.standardError.write(
            "--threads must be 256: the kernel hardcodes GROUP_SIZE 256\n".data(using: .utf8)!)
        return 2
    }
    let threadsPerGroup = config.threadsPerGroup
    let hashesPerDispatch = UInt64(config.groups) * UInt64(threadsPerGroup)
    guard config.inflight > 0 else {
        FileHandle.standardError.write("--inflight must be at least 1\n".data(using: .utf8)!)
        return 2
    }
    let sem = DispatchSemaphore(value: config.inflight)
    var baseNonce: UInt64 = 0

    func encode(_ cb: MTLCommandBuffer) {
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setBuffer(dag.dag,    offset: 0, index: 0)
        enc.setBuffer(headerBuf,  offset: 0, index: 1)
        enc.setBuffer(resultsBuf, offset: 0, index: 2)
        enc.setBuffer(indexBuf,   offset: 0, index: 3)
        enc.setBuffer(stopBuf,    offset: 0, index: 4)
        var bn = baseNonce
        var tg = target
        var de = dagElements
        var pm: UInt32 = 0
        var pn: UInt64 = 0
        enc.setBytes(&bn, length: 8, index: 5)
        enc.setBytes(&tg, length: 8, index: 6)
        enc.setBytes(&de, length: 4, index: 7)
        enc.setBytes(&pm, length: 4, index: 8)
        enc.setBytes(&pn, length: 8, index: 9)
        enc.dispatchThreadgroups(
            MTLSize(width: Int(config.groups), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: Int(threadsPerGroup), height: 1, depth: 1)
        )
        enc.endEncoding()
        baseNonce += hashesPerDispatch
    }

    func drain() { for _ in 0..<config.inflight { sem.wait() } }

    // --- warm-up (not counted) -------------------------------------------
    print("\n--- warm-up ---")
    for _ in 0..<config.inflight {
        let cb = queue.makeCommandBuffer()!
        cb.addCompletedHandler { _ in sem.signal() }
        encode(cb)
        cb.commit()
    }
    drain()
    baseNonce = 0
    memset(stopBuf.contents(), 0, 4)
    memset(indexBuf.contents(), 0, 4)

    // --- measured run -----------------------------------------------------
    print("--- measuring for \(config.minutes) min ---")
    let powerSampler = GpuPowerSampler()
    if powerSampler == nil {
        print("  note: IOReport GPU energy channel unavailable; power will not be reported")
    }
    let start = Date()
    let energyStart = powerSampler?.gpuJoules()
    var lastEnergy = energyStart
    let deadline = start.addingTimeInterval(config.minutes * 60)
    var nextSample = start.addingTimeInterval(config.sampleSeconds)
    var totalHashes: UInt64 = 0
    var lastSampleHashes: UInt64 = 0
    var lastSampleTime = start
    var wins = 0
    var samples: [[String: Any]] = []
    var utilValues: [Int] = []
    var powerValues: [Double] = []

    while Date() < deadline {
        sem.wait()
        let cb = queue.makeCommandBuffer()!
        cb.addCompletedHandler { _ in sem.signal() }
        encode(cb)
        cb.commit()
        totalHashes += hashesPerDispatch

        // A non-zero target can produce a winner; count it and clear the flags
        // so the rest of the run is not aborted by the kernel's early exit.
        let stopPtr = stopBuf.contents().assumingMemoryBound(to: UInt32.self)
        if stopPtr[0] != 0 {
            wins += 1
            stopPtr[0] = 0
            indexBuf.contents().assumingMemoryBound(to: UInt32.self)[0] = 0
        }

        let now = Date()
        if now >= nextSample {
            let intervalHashes = totalHashes - lastSampleHashes
            let intervalTime = now.timeIntervalSince(lastSampleTime)
            let mh = Double(intervalHashes) / intervalTime / 1e6
            let util = sampleGpuUtilisation()
            if let d = util?.device { utilValues.append(d) }
            let thermal = sampleThermalPressure()

            // GPU power = delta of the monotonic IOReport energy counter.
            var power: Double? = nil
            if let sampler = powerSampler, let e = sampler.gpuJoules(), let previous = lastEnergy,
               intervalTime > 0 {
                power = (e - previous) / intervalTime
                lastEnergy = e
            }
            if let p = power { powerValues.append(p) }

            let elapsed = now.timeIntervalSince(start)
            print(String(format: "  t=%6.0fs  %7.2f MH/s  %6.2f W  gpu[%@]  therm: %@",
                         elapsed, mh, power ?? 0, util?.summary ?? "n/a", thermal))
            samples.append([
                "elapsed_s": elapsed,
                "interval_mhps": mh,
                "cumulative_mhps": Double(totalHashes) / elapsed / 1e6,
                "gpu_power_w": power ?? -1,
                "gpu": util?.summary ?? "n/a",
                "gpu_device_util": util?.device ?? -1,
                "thermal": thermal,
            ])
            lastSampleHashes = totalHashes
            lastSampleTime = now
            nextSample = now.addingTimeInterval(config.sampleSeconds)
        }
    }
    drain()

    let elapsed = Date().timeIntervalSince(start)
    let mhps = Double(totalHashes) / elapsed / 1e6
    let steady = samples.dropFirst().compactMap { $0["interval_mhps"] as? Double }
    let steadyAvg = steady.isEmpty ? mhps : steady.reduce(0, +) / Double(steady.count)
    let utilAvg = utilValues.isEmpty ? nil : utilValues.reduce(0, +) / utilValues.count
    let utilMax = utilValues.max()
    let thermal = sampleThermalPressure()

    // Whole-window energy, independent of the per-sample counter reads.
    var energyUsed: Double? = nil
    var avgPower: Double? = nil
    if let sampler = powerSampler, let e0 = energyStart, let e1 = sampler.gpuJoules(), e1 >= e0 {
        energyUsed = e1 - e0
        if elapsed > 0 { avgPower = energyUsed! / elapsed }
    }

    print("\n=== results ===")
    print(String(format: "hashes:            %llu", totalHashes))
    print(String(format: "elapsed:           %.1f s", elapsed))
    print(String(format: "hashrate:          %.2f MH/s  (%.4f GH/s)", mhps, mhps / 1000))
    print(String(format: "steady state:      %.2f MH/s  (excluding first sample interval)", steadyAvg))
    print("wins (target hit): \(wins)\(target == 0 ? "  (expected 0: target is 0)" : "")")
    print("gpu utilisation:   \(utilAvg.map { "avg \($0)%" } ?? "n/a")\(utilMax.map { ", max \($0)%" } ?? "")")
    print("thermal:           \(thermal)")
    if let p = avgPower {
        let peak = powerValues.max()
        print(String(format: "gpu power:         avg %.2f W%@  (%.0f mJ total, IOReport GPU Energy)",
                     p, peak.map { String(format: ", peak %.2f W", $0) } ?? "", (energyUsed ?? 0) * 1000))
        print(String(format: "efficiency:        %.3f J/MH  (%.2f MH/s per watt)",
                     (energyUsed ?? 0) / Double(totalHashes) * 1e6, mhps / p))
    } else {
        print("gpu power:         unavailable (IOReport GPU Energy channel not found)")
    }
    print(String(format: "reference:         GTX 1080 Ti ~22-24 MH/s -> this M4 Pro is %.1f-%.1f%% of that",
                 mhps / 24.0 * 100, mhps / 22.0 * 100))
    print("validation:        \(validationNote)")

    if let out = config.jsonOut {
        let payload: [String: Any] = [
            "device": device.name,
            "height": config.height,
            "epoch": epoch,
            "prog_seed": period,
            "header_hash": headerHex,
            "target": String(format: "%016llx", target),
            "groups": config.groups,
            "threads_per_group": threadsPerGroup,
            "hashes_per_dispatch": hashesPerDispatch,
            "duration_minutes": config.minutes,
            "total_hashes": totalHashes,
            "elapsed_s": elapsed,
            "hashrate_mhps": mhps,
            "steady_state_mhps": steadyAvg,
            "wins": wins,
            "gpu_util_avg": utilAvg ?? -1,
            "gpu_util_max": utilMax ?? -1,
            "gpu_power_avg_w": avgPower ?? -1,
            "gpu_power_peak_w": powerValues.max() ?? -1,
            "gpu_energy_j": energyUsed ?? -1,
            "joules_per_mh": energyUsed.map { $0 / Double(totalHashes) * 1e6 } ?? -1,
            "thermal": thermal,
            "validation": validationNote,
            "dag_elements": dagElements,
            "samples": samples,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    }

    return 0
}
