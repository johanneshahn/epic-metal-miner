import Foundation
import Metal

// ===========================================================================
// Phase 2 — correctness validation.
//
// The gate is: the Metal kernel's own output must equal the 12 official
// ProgPoW 0.9.2 test vectors (progpow-rust/pp_light/res/progpow_testvectors.json).
// There is deliberately no CPU hash fallback in this path: the values compared
// against the vectors come from the GPU.
//
// The kernel exposes a "probe" mode for this purpose: instead of reporting the
// first nonce under a target, it reports the full mix digest and final hash for
// one nominated nonce. The probe reuses the identical algorithm path as mining
// (same fill_mix, same inner loop, same two keccak-f800 permutations), so a
// probe PASS is evidence about the mining path.
//
// A separate cross-check validates the GPU-built DAG (and therefore c_dag, the
// first 16 KiB of the DAG) against the Rust reference via `epic_oracle.json`.
// ===========================================================================

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

func hexToBytes(_ s: String) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(s.count / 2)
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

func bytesToHex(_ b: [UInt8]) -> String {
    var s = ""
    s.reserveCapacity(b.count * 2)
    for x in b { s += String(format: "%02x", x) }
    return s
}

extension Array where Element == UInt8 {
    var hexString: String { bytesToHex(self) }
}

/// Words -> bytes, little-endian per word. This is the byte order Epic's node
/// produces (`transmute([u32;8]) -> [u8;32]` in core/src/pow/progpow.rs), and
/// the byte order the official vectors are encoded in.
func wordsToBytesLE(_ w: [UInt32]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(w.count * 4)
    for x in w {
        out.append(UInt8(x & 0xff))
        out.append(UInt8((x >> 8) & 0xff))
        out.append(UInt8((x >> 16) & 0xff))
        out.append(UInt8((x >> 24) & 0xff))
    }
    return out
}

/// Words -> bytes, big-endian per word. Only used to *report* the classic
/// byte-order mistake when a comparison fails.
func wordsToBytesBE(_ w: [UInt32]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(w.count * 4)
    for x in w {
        out.append(UInt8((x >> 24) & 0xff))
        out.append(UInt8((x >> 16) & 0xff))
        out.append(UInt8((x >> 8) & 0xff))
        out.append(UInt8(x & 0xff))
    }
    return out
}

func u32FromLE(_ b: ArraySlice<UInt8>) -> UInt32 {
    let a = Array(b)
    return UInt32(a[0]) | (UInt32(a[1]) << 8) | (UInt32(a[2]) << 16) | (UInt32(a[3]) << 24)
}

// ---------------------------------------------------------------------------
// Official test vectors
// ---------------------------------------------------------------------------

struct EpicTestVector {
    let blockNumber: UInt64
    let headerHash: [UInt8]      // 32 bytes, keccak-256 of the header
    let nonce: UInt64
    let mixHash: [UInt8]         // 32 bytes, expected
    let finalHash: [UInt8]       // 32 bytes, expected

    var epoch: UInt64 { blockNumber / Ethash.EPIC_EPOCH_LENGTH }
    var progSeed: UInt64 { blockNumber / UInt64(EpicProgPow.PROGPOW_PERIOD) }
    /// The kernel takes the header hash as 8 little-endian u32 words.
    var headerWords: [UInt32] {
        (0..<8).map { u32FromLE(headerHash[($0 * 4)..<($0 * 4 + 4)]) }
    }
}

func loadEpicVectors() throws -> [EpicTestVector] {
    guard let url = Bundle.module.url(forResource: "progpow_testvectors", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
        throw EpicKernelError.resourceMissing("progpow_testvectors.json")
    }
    return raw.map { row in
        EpicTestVector(
            blockNumber: UInt64(row[0] as! Int),
            headerHash: hexToBytes(row[1] as! String),
            nonce: UInt64(row[2] as! String, radix: 16)!,
            mixHash: hexToBytes(row[3] as! String),
            finalHash: hexToBytes(row[4] as! String)
        )
    }
}

// ---------------------------------------------------------------------------
// Rust-oracle DAG/seed data (produced by ../oracle, which links progpow-rust)
// ---------------------------------------------------------------------------

struct EpicDagProbeNode {
    let index: UInt32
    let words: [UInt32]
}

struct EpicOracleVector {
    let index: Int
    let blockNumber: UInt64
    let epoch: UInt64
    let dagElements: UInt32
    let seed: UInt64
    let cdagFnv: UInt32
    let cdagRotSum: UInt32
    let cdagFirstWords: [UInt32]
    let cdagLastWords: [UInt32]
    let probeNodes: [EpicDagProbeNode]
}

func loadEpicOracle() throws -> [EpicOracleVector] {
    guard let url = Bundle.module.url(forResource: "epic_oracle", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw EpicKernelError.resourceMissing("epic_oracle.json")
    }
    return rows.map { row in
        // "fnv1a=df8c48da rot_sum=c2ba63f7 w0=2922db22 w1=466c51cc"
        let parts = (row["cdag_fnv1a"] as! String).split(separator: " ")
        func hexField(_ p: Substring) -> UInt32 {
            UInt32(p.split(separator: "=")[1], radix: 16)!
        }
        let nodes = (row["dag_probe_nodes"] as! [[String: Any]]).map { n in
            EpicDagProbeNode(index: UInt32(n["index"] as! Int),
                             words: (n["words"] as! [Int]).map { UInt32($0) })
        }
        return EpicOracleVector(
            index: row["index"] as! Int,
            blockNumber: UInt64(row["block_number"] as! Int),
            epoch: UInt64(row["epoch"] as! Int),
            dagElements: UInt32(row["dag_elements"] as! Int),
            seed: UInt64(row["seed"] as! String, radix: 16)!,
            cdagFnv: hexField(parts[0]),
            cdagRotSum: hexField(parts[1]),
            cdagFirstWords: (row["cdag_first_words"] as! [Int]).map { UInt32($0) },
            cdagLastWords: (row["cdag_last_words"] as! [Int]).map { UInt32($0) },
            probeNodes: nodes
        )
    }
}

/// Same fingerprint the Rust oracle prints, so the two are directly comparable:
/// FNV-1a over all 4096 c_dag words, plus a rotation-position-weighted sum.
func cdagFingerprint<C: Collection>(_ words: C) -> (fnv: UInt32, rotSum: UInt32) where C.Element == UInt32 {
    var fnv: UInt32 = 0x811c9dc5
    var rotSum: UInt32 = 0
    for (i, w) in words.enumerated() {
        fnv = (fnv ^ w) &* 0x01000193
        rotSum = rotSum &+ rotl32(w, UInt32(i % 32))
    }
    return (fnv, rotSum)
}

/// Left-rotate a 32-bit word (Swift's stdlib has no rotation operator).
@inline(__always) func rotl32(_ x: UInt32, _ n: UInt32) -> UInt32 {
    let s = n & 31
    return s == 0 ? x : (x << s) | (x >> (32 - s))
}

// ---------------------------------------------------------------------------
// GPU probe dispatch
// ---------------------------------------------------------------------------

struct EpicProbeResult {
    let nonce: UInt64
    let mix: [UInt32]     // 8 words, the per-lane FNV reduction
    let final: [UInt32]   // 8 words, state_b[0..7] after the second permutation
}

/// Run the search kernel in probe mode for exactly one nonce.
///
/// `baseNonce` is set to the requested nonce, so grid position 0 owns it; a
/// single 256-thread threadgroup is enough (the probe nonce must land on a
/// lane-0 of some group, which it does at offset 0).
func runEpicProbe(device: MTLDevice,
                  queue: MTLCommandQueue,
                  pso: MTLComputePipelineState,
                  dag: MTLBuffer,
                  dagElements: UInt32,
                  headerWords: [UInt32],
                  nonce: UInt64) throws -> EpicProbeResult {
    let resultsBuf = device.makeBuffer(length: 64 * 4, options: .storageModeShared)!
    let indexBuf   = device.makeBuffer(length: 4, options: .storageModeShared)!
    let stopBuf    = device.makeBuffer(length: 4, options: .storageModeShared)!
    let headerBuf  = device.makeBuffer(bytes: headerWords, length: 8 * 4, options: .storageModeShared)!

    memset(resultsBuf.contents(), 0, 64 * 4)
    memset(indexBuf.contents(), 0, 4)
    memset(stopBuf.contents(), 0, 4)

    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(dag,        offset: 0, index: 0)
    enc.setBuffer(headerBuf,  offset: 0, index: 1)
    enc.setBuffer(resultsBuf, offset: 0, index: 2)
    enc.setBuffer(indexBuf,   offset: 0, index: 3)
    enc.setBuffer(stopBuf,    offset: 0, index: 4)
    var baseNonce = nonce
    var target: UInt64 = 0
    var dagElementsLocal = dagElements
    var probeMode: UInt32 = 1
    var probeNonce = nonce
    enc.setBytes(&baseNonce,       length: 8, index: 5)
    enc.setBytes(&target,          length: 8, index: 6)
    enc.setBytes(&dagElementsLocal, length: 4, index: 7)
    enc.setBytes(&probeMode,       length: 4, index: 8)
    enc.setBytes(&probeNonce,      length: 8, index: 9)

    enc.dispatchThreadgroups(
        MTLSize(width: 1, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
    )
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    if let e = cb.error { throw EpicKernelError.compileFailed("probe dispatch: \(e)") }

    let stop = stopBuf.contents().assumingMemoryBound(to: UInt32.self)[0]
    guard stop == 1 else {
        throw EpicKernelError.functionMissing("probe nonce \(String(format: "%016llx", nonce)) never reached the output stage")
    }
    let p = resultsBuf.contents().assumingMemoryBound(to: UInt32.self)
    let gotNonce = UInt64(p[0]) | (UInt64(p[1]) << 32)
    guard gotNonce == nonce else {
        throw EpicKernelError.functionMissing("probe reported nonce \(String(format: "%016llx", gotNonce)), wanted \(String(format: "%016llx", nonce))")
    }
    let mix = (0..<8).map { p[2 + $0] }
    let final = (0..<8).map { p[10 + $0] }
    return EpicProbeResult(nonce: gotNonce, mix: mix, final: final)
}

// ---------------------------------------------------------------------------
// Harness 1 — the 12 official vectors on the GPU
// ---------------------------------------------------------------------------

func runEpicVectorTest(device: MTLDevice) throws -> Bool {
    let vectors = try loadEpicVectors()
    let oracle = try loadEpicOracle()
    let queue = device.makeCommandQueue()!

    print("=== Epic ProgPoW 0.9.2 — GPU known-answer test ===")
    print("device: \(device.name)")
    print("vectors: \(vectors.count)  epochs: \(Set(vectors.map { $0.epoch }).sorted())")

    var dagCache: [UInt64: DAGOutput] = [:]
    var psoCache: [UInt64: MTLComputePipelineState] = [:]
    var pass = 0
    var fail = 0

    for (i, v) in vectors.enumerated() {
        let o = oracle[i]
        let dag: DAGOutput
        if let cached = dagCache[v.epoch] {
            dag = cached
        } else {
            print("\n--- building epoch \(v.epoch) DAG on GPU (needed by block \(v.blockNumber)) ---")
            dag = try buildDAG(device: device, epoch: v.epoch)
            dagCache[v.epoch] = dag
        }
        let dagElements = dag.dagNumItems / 4

        let pso: MTLComputePipelineState
        if let cached = psoCache[v.progSeed] {
            pso = cached
        } else {
            pso = try compileEpicKernel(device: device, progSeed: v.progSeed)
            psoCache[v.progSeed] = pso
        }

        let epochOK = UInt64(o.epoch) == v.epoch
        let dagElementsOK = dagElements == o.dagElements

        let r = try runEpicProbe(device: device, queue: queue, pso: pso, dag: dag.dag,
                                 dagElements: dagElements, headerWords: v.headerWords, nonce: v.nonce)
        let gotMix = wordsToBytesLE(r.mix)
        let gotFinal = wordsToBytesLE(r.final)
        let mixOK = gotMix == v.mixHash
        let finalOK = gotFinal == v.finalHash

        if mixOK && finalOK && epochOK && dagElementsOK { pass += 1 } else { fail += 1 }

        print(String(format: "[%2d] block=%7llu epoch=%3llu period=%6llu nonce=%016llx  mix=%@ final=%@",
                     i, v.blockNumber, v.epoch, v.progSeed, v.nonce,
                     mixOK ? "PASS" : "FAIL", finalOK ? "PASS" : "FAIL"))
        if !dagElementsOK {
            print("       dag_elements: got \(dagElements), oracle \(o.dagElements)  <-- epoch/size mismatch")
        }
        if !epochOK { print("       epoch: got \(v.epoch), oracle \(o.epoch)") }
        if !mixOK {
            print("       expected mix  \(bytesToHex(v.mixHash))")
            print("       got      mix  \(bytesToHex(gotMix))  (LE words)")
            print("       got      mix  \(bytesToHex(wordsToBytesBE(r.mix)))  (BE words)")
        }
        if !finalOK {
            print("       expected final \(bytesToHex(v.finalHash))")
            print("       got      final \(bytesToHex(gotFinal))  (LE words)")
            print("       got      final \(bytesToHex(wordsToBytesBE(r.final)))  (BE words)")
            print(String(format: "       oracle seed   %016llx", o.seed))
        }
    }

    print("\n=== result: \(pass)/\(vectors.count) vectors PASS on the Metal GPU, \(fail) FAIL ===")
    return fail == 0
}

// ---------------------------------------------------------------------------
// Harness 2 — GPU DAG vs Rust reference (validates c_dag implicitly)
// ---------------------------------------------------------------------------

func runEpicDagCrossCheck(device: MTLDevice) throws -> Bool {
    let oracle = try loadEpicOracle()
    print("=== Epic ProgPoW 0.9.2 — GPU DAG / c_dag cross-check ===")
    print("device: \(device.name)")

    var failures = 0
    for epoch in Set(oracle.map { $0.epoch }).sorted() {
        guard let ref = oracle.first(where: { $0.epoch == epoch }) else { continue }
        print("\n--- epoch \(epoch) ---")
        let dag = try buildDAG(device: device, epoch: epoch)
        let words = dag.dag.contents().assumingMemoryBound(to: UInt32.self)
        let dagElements = dag.dagNumItems / 4

        if dagElements != ref.dagElements {
            print("  dag_elements: got \(dagElements), oracle \(ref.dagElements)  FAIL")
            failures += 1
        } else {
            print("  dag_elements: \(dagElements)  PASS")
        }

        for node in ref.probeNodes {
            let base = Int(node.index) * 16
            let got = (0..<16).map { words[base + $0] }
            let ok = got == node.words
            if !ok { failures += 1 }
            print("  DAG item \(node.index): \(ok ? "PASS" : "FAIL")")
            if !ok {
                print("    expected \(node.words.map { String(format: "%08x", $0) }.joined(separator: " "))")
                print("    got      \(got.map { String(format: "%08x", $0) }.joined(separator: " "))")
            }
        }

        // c_dag = the first 4096 words of the DAG (= DAG items 0..255)
        let cdag = UnsafeBufferPointer(start: words, count: 4096)
        let fp = cdagFingerprint(cdag)
        let fnvOK = fp.fnv == ref.cdagFnv && fp.rotSum == ref.cdagRotSum
        if !fnvOK { failures += 1 }
        print(String(format: "  c_dag fingerprint: %@  (got fnv=%08x rot=%08x, oracle fnv=%08x rot=%08x)",
                     fnvOK ? "PASS" : "FAIL", fp.fnv, fp.rotSum, ref.cdagFnv, ref.cdagRotSum))
        let first16 = (0..<16).map { words[$0] }
        let last16 = (0..<16).map { words[4096 - 16 + $0] }
        let edgesOK = first16 == ref.cdagFirstWords && last16 == ref.cdagLastWords
        if !edgesOK { failures += 1 }
        print("  c_dag edges (first/last 16 words): \(edgesOK ? "PASS" : "FAIL")")
    }

    print("\n=== DAG cross-check: \(failures == 0 ? "PASS" : "FAIL (\(failures) mismatches)") ===")
    return failures == 0
}
