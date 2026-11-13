import Foundation

// Epic Cash Stratum protocol values. See ../../EPIC_MINING_PROTOCOL.md.
// These types intentionally model only the ProgPow-capable subset; unsupported
// template algorithms are represented so the job controller can stop safely.

enum EpicMiningError: Error, CustomStringConvertible {
    case invalidEndpoint(String)
    case malformedMessage(String)
    case malformedTemplate(String)
    case missingDifficulty(EpicAlgorithm)
    case unsupportedAlgorithm(String)

    var description: String {
        switch self {
        case .invalidEndpoint(let s): return "invalid endpoint: \(s)"
        case .malformedMessage(let s): return "malformed RPC message: \(s)"
        case .malformedTemplate(let s): return "malformed job template: \(s)"
        case .missingDifficulty(let a): return "job has no \(a.rawValue) difficulty"
        case .unsupportedAlgorithm(let s): return "unsupported mining algorithm: \(s)"
        }
    }
}

enum EpicAlgorithm: String, Codable, CaseIterable {
    case cuckoo
    case randomx
    case progpow
}

struct EpicDifficultyEntry: Codable, Equatable {
    let algorithm: String
    let value: UInt64

    init(algorithm: String, value: UInt64) {
        self.algorithm = algorithm
        self.value = value
    }

    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        algorithm = try values.decode(String.self)
        value = try values.decode(UInt64.self)
        guard values.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: values, debugDescription: "difficulty entry must contain two values")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(algorithm)
        try values.encode(value)
    }
}

struct EpicJobTemplate: Codable {
    let height: UInt64
    let jobID: UInt64
    let difficulty: [EpicDifficultyEntry]
    let blockDifficulty: [EpicDifficultyEntry]
    let prePowHex: String
    let epochs: [[JSONValue]]
    let algorithm: String

    enum CodingKeys: String, CodingKey {
        case height
        case jobID = "job_id"
        case difficulty
        case blockDifficulty = "block_difficulty"
        case prePowHex = "pre_pow"
        case epochs
        case algorithm
    }

    func shareDifficulty(for algorithm: EpicAlgorithm) throws -> UInt64 {
        guard let value = difficulty.first(where: { $0.algorithm == algorithm.rawValue })?.value,
              value > 0 else { throw EpicMiningError.missingDifficulty(algorithm) }
        return value
    }

    func networkDifficulty(for algorithm: EpicAlgorithm) throws -> UInt64 {
        guard let value = blockDifficulty.first(where: { $0.algorithm == algorithm.rawValue })?.value,
              value > 0 else { throw EpicMiningError.missingDifficulty(algorithm) }
        return value
    }

    func validatedPrePow() throws -> [UInt8] {
        guard prePowHex.count.isMultiple(of: 2), prePowHex.count >= 2,
              prePowHex.allSatisfy({ $0.isHexDigit }) else {
            throw EpicMiningError.malformedTemplate("pre_pow is not even-length hexadecimal")
        }
        let bytes = hexToBytes(prePowHex)
        // Current consensus serialization is 274 bytes. This guard catches
        // malformed jobs; retaining the decoded byte count in errors ensures a
        // future consensus change is investigated rather than silently hashed.
        guard bytes.count == 274 else {
            throw EpicMiningError.malformedTemplate("pre_pow is \(bytes.count) bytes; expected current 274-byte serialization")
        }
        return bytes
    }

    func fingerprint() throws -> String {
        let prePow = try validatedPrePow()
        let canonical = "\(height)|\(jobID)|\(algorithm)|\(shareDifficultyOrZero())|\(bytesToHex(prePow))"
        return bytesToHex(Keccak.keccak256(Array(canonical.utf8)))
    }

    private func shareDifficultyOrZero() -> UInt64 {
        difficulty.first(where: { $0.algorithm == EpicAlgorithm.progpow.rawValue })?.value ?? 0
    }
}

/// Generic JSON value used solely for the RandomX-only `epochs` field. The
/// native ProgPow client deliberately preserves but never interprets it.
enum JSONValue: Codable {
    case string(String), number(UInt64), array([JSONValue]), object([String: JSONValue]), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(UInt64.self) { self = .number(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

/// Full Epic difficulty boundary. The reference miner uses only the first
/// 64 bits as a GPU prefilter; submission safety requires this complete value.
struct EpicShareTarget: Equatable {
    /// Four most-significant-first, big-endian 64-bit limbs.
    let boundary: [UInt64]

    init(difficulty: UInt64) throws {
        guard difficulty > 0 else {
            throw EpicMiningError.malformedTemplate("ProgPow difficulty is zero")
        }
        // Long-divide (2^256 - 1) by a u64 using FixedWidthInteger's exact
        // 128/64 primitive. The carry is always less than `difficulty`.
        var remainder: UInt64 = 0
        var quotient: [UInt64] = []
        quotient.reserveCapacity(4)
        for _ in 0..<4 {
            let result = difficulty.dividingFullWidth((high: remainder, low: .max))
            quotient.append(result.quotient)
            remainder = result.remainder
        }
        boundary = quotient
    }

    /// Value supplied to `epic_search` for its compatible top-64-bit filter.
    var gpuPrefilter: UInt64 { boundary[0] }

    var bigEndianBytes: [UInt8] {
        boundary.flatMap { word in
            (0..<8).reversed().map { UInt8(truncatingIfNeeded: word >> UInt64($0 * 8)) }
        }
    }

    /// `finalWords` use Epic's native little-endian-per-word serialization.
    /// Comparing their byte serialization with the big-endian boundary exactly
    /// implements `final_hash_be <= floor((2^256 - 1) / difficulty)`.
    func accepts(finalWords: [UInt32]) -> Bool {
        let digest = wordsToBytesLE(finalWords)
        precondition(digest.count == 32)
        for i in 0..<32 {
            if digest[i] != bigEndianBytes[i] { return digest[i] < bigEndianBytes[i] }
        }
        return true
    }
}

struct EpicMiningJob {
    let generation: UInt64
    let template: EpicJobTemplate
    let prePow: [UInt8]
    let headerHash: [UInt8]
    let shareTarget: EpicShareTarget
    let networkTarget: EpicShareTarget
    let fingerprint: String

    init(generation: UInt64, template: EpicJobTemplate) throws {
        guard template.algorithm == EpicAlgorithm.progpow.rawValue else {
            throw EpicMiningError.unsupportedAlgorithm(template.algorithm)
        }
        let prePow = try template.validatedPrePow()
        self.generation = generation
        self.template = template
        self.prePow = prePow
        self.headerHash = Keccak.keccak256(prePow)
        self.shareTarget = try EpicShareTarget(difficulty: template.shareDifficulty(for: .progpow))
        self.networkTarget = try EpicShareTarget(difficulty: template.networkDifficulty(for: .progpow))
        self.fingerprint = try template.fingerprint()
    }

    var epoch: UInt64 { template.height / Ethash.EPIC_EPOCH_LENGTH }
    var progSeed: UInt64 { template.height / UInt64(EpicProgPow.PROGPOW_PERIOD) }
    var headerWords: [UInt32] {
        (0..<8).map { u32FromLE(headerHash[($0 * 4)..<($0 * 4 + 4)]) }
    }
}

/// Focused, dependency-free regression test for the critical difficulty math.
/// `protocol-selftest` runs it alongside the live read-only endpoint check.
func runEpicProtocolSelfTest() throws {
    let diff1 = try EpicShareTarget(difficulty: 1)
    guard diff1.bigEndianBytes == [UInt8](repeating: 0xff, count: 32),
          diff1.gpuPrefilter == .max else {
        throw EpicMiningError.malformedMessage("difficulty 1 boundary regression")
    }
    let diff2 = try EpicShareTarget(difficulty: 2)
    guard diff2.bigEndianBytes[0] == 0x7f,
          diff2.bigEndianBytes.dropFirst().allSatisfy({ $0 == 0xff }),
          diff2.gpuPrefilter == 0x7fff_ffff_ffff_ffff else {
        throw EpicMiningError.malformedMessage("difficulty 2 boundary regression")
    }
    let allOnes = [UInt32](repeating: .max, count: 8)
    let zero = [UInt32](repeating: 0, count: 8)
    guard !diff2.accepts(finalWords: allOnes), diff2.accepts(finalWords: zero) else {
        throw EpicMiningError.malformedMessage("full target comparison regression")
    }
    let liveShare = try EpicShareTarget(difficulty: 200_000)
    guard liveShare.gpuPrefilter == 0x0000_53e2_d623_8da3 else {
        throw EpicMiningError.malformedMessage("ProgPow 200000 prefilter regression")
    }
    print("Epic protocol target self-test: PASS")
}
