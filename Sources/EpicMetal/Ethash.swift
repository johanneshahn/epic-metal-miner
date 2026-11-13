import Foundation

// ethash sizing + light cache generation for Epic Cash ProgPoW.
//
// ProgPoW uses the unmodified ethash DAG/cache machinery: 30000 blocks per
// epoch and 256 dataset parents (Epic/progpow-rust `pp_light/src/shared.rs:19-28`,
// `compute.rs:293-312`). Only the search algorithm on top is ProgPoW 0.9.2.
//
// Cache size grows linearly with epoch, rounded down to a multiple of HASH_BYTES
// such that (size / HASH_BYTES) is prime. Same for the DAG.
//
// Adapted from kawpow-mac/Sources/kawpow-mac/Ethash.swift (GPLv3): the only
// algorithmic change is the epoch length (7500 -> 30000) and the removal of the
// pool-specific seed->epoch search, which ProgPoW does not need.

enum Ethash {
    static let DATASET_BYTES_INIT:   UInt64 = 1 << 30   // 1 GB
    static let DATASET_BYTES_GROWTH: UInt64 = 1 << 23   // 8 MB per epoch
    static let CACHE_BYTES_INIT:     UInt64 = 1 << 24   // 16 MB
    static let CACHE_BYTES_GROWTH:   UInt64 = 1 << 17   // 128 KB per epoch
    static let HASH_BYTES:           UInt64 = 64        // one keccak-512 output
    static let MIX_BYTES:            UInt64 = 128
    static let DATASET_PARENTS:      UInt64 = 256
    static let CACHE_ROUNDS:         UInt64 = 3

    static let EPIC_EPOCH_LENGTH: UInt64 = 30000

    static func epoch(forBlockHeight h: UInt64) -> UInt64 {
        return h / EPIC_EPOCH_LENGTH
    }

    static func cacheSize(epoch: UInt64) -> UInt64 {
        var sz = CACHE_BYTES_INIT + CACHE_BYTES_GROWTH * epoch
        sz -= HASH_BYTES
        while !isPrime(sz / HASH_BYTES) {
            sz -= 2 * HASH_BYTES
        }
        return sz
    }

    static func datasetSize(epoch: UInt64) -> UInt64 {
        var sz = DATASET_BYTES_INIT + DATASET_BYTES_GROWTH * epoch
        sz -= MIX_BYTES
        while !isPrime(sz / MIX_BYTES) {
            sz -= 2 * MIX_BYTES
        }
        return sz
    }

    // seed = keccak256 iterated `epoch` times starting from 0...0
    static func seedHash(epoch: UInt64) -> [UInt8] {
        var s = [UInt8](repeating: 0, count: 32)
        for _ in 0..<epoch {
            s = Keccak.keccak256(s)
        }
        return s
    }

    // Given a seed produced by a pool, find the epoch that generates it
    // by iterating keccak256 from zeros. ProgPoW derives the epoch directly
    // from `height / 30000`, so this is only used as a sanity cross-check.
    static func epochFromSeed(_ targetSeed: [UInt8], maxSearch: Int = 5000) -> UInt64? {
        var s = [UInt8](repeating: 0, count: 32)
        if s == targetSeed { return 0 }
        for i in 1...maxSearch {
            s = Keccak.keccak256(s)
            if s == targetSeed { return UInt64(i) }
        }
        return nil
    }

    // ─── Light cache generation ────────────────────────────────────────────
    // cache[0] = keccak_512(seed); cache[i] = keccak_512(cache[i-1]).
    // Then CACHE_ROUNDS of RandMemoHash mixing.
    static func makeCache(epoch: UInt64) -> [UInt8] {
        let size = Int(cacheSize(epoch: epoch))
        let nodeCount = size / Int(HASH_BYTES)
        let seed = seedHash(epoch: epoch)

        var cache = [UInt8](repeating: 0, count: size)
        cache.withUnsafeMutableBufferPointer { bufp in
            let p = bufp.baseAddress!

            // First node: keccak_512(32-byte seed) — uses the general (slow) path
            // once, since input is 32 bytes, not 64. Negligible cost (1 call).
            let firstNode = Keccak.keccak512(seed)
            for i in 0..<64 { p[i] = firstNode[i] }

            // Subsequent nodes — chain keccak_512 on 64-byte blocks.
            for i in 1..<nodeCount {
                Keccak.keccak512_64(p + (i - 1) * 64, p + i * 64)
            }

            // RandMemoHash rounds: cache[i] = keccak_512(cache[i-1] XOR cache[v])
            var tmp = [UInt8](repeating: 0, count: 64)
            tmp.withUnsafeMutableBufferPointer { tmpBuf in
                let t = tmpBuf.baseAddress!
                for _ in 0..<Int(CACHE_ROUNDS) {
                    for i in 0..<nodeCount {
                        let off = i * 64
                        // v = cache[i][0..3] as little-endian uint32 mod n
                        let v32 =
                              UInt32(p[off + 0])
                            | UInt32(p[off + 1]) << 8
                            | UInt32(p[off + 2]) << 16
                            | UInt32(p[off + 3]) << 24
                        let v = Int(v32) % nodeCount
                        let lOff = ((i + nodeCount - 1) % nodeCount) * 64
                        let rOff = v * 64
                        // XOR two 64-byte nodes — do it 8 bytes at a time
                        let lp = (p + lOff).withMemoryRebound(to: UInt64.self, capacity: 8) { $0 }
                        let rp = (p + rOff).withMemoryRebound(to: UInt64.self, capacity: 8) { $0 }
                        let tp = t.withMemoryRebound(to: UInt64.self, capacity: 8) { $0 }
                        for q in 0..<8 { tp[q] = lp[q] ^ rp[q] }
                        Keccak.keccak512_64(t, p + off)
                    }
                }
            }
        }
        return cache
    }
}

// Miller–Rabin would be overkill for the modest sizes we test here (~1.5M-25M);
// trial division up to sqrt(n) is fine. Cache sizing only ever runs once.
func isPrime(_ n: UInt64) -> Bool {
    if n < 2 { return false }
    if n < 4 { return true }
    if n % 2 == 0 { return false }
    if n % 3 == 0 { return false }
    var i: UInt64 = 5
    while i * i <= n {
        if n % i == 0 { return false }
        if n % (i + 2) == 0 { return false }
        i += 6
    }
    return true
}
