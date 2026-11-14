import Foundation
import Metal

// Assembly + compilation of the Epic ProgPoW search kernel.
//
// Only the per-period program (RANDOM_MATH / DATA_LOADS) is generated into the
// source. Everything that changes per job — target, DAG element count, base
// nonce, height/probe — is a runtime argument, because Epic's ProgPoW
// difficulty changes every block and a per-job recompile would stall the miner
// (audit §5.1, R5).

enum EpicKernelError: Error, CustomStringConvertible {
    case resourceMissing(String)
    case compileFailed(String)
    case functionMissing(String)

    var description: String {
        switch self {
        case .resourceMissing(let n): return "resource missing: \(n)"
        case .compileFailed(let m):   return "kernel compile failed: \(m)"
        case .functionMissing(let n): return "function missing: \(n)"
        }
    }
}

/// `noPostDagBarrier` is the validated production default. `standard` remains
/// available as an explicit rollback selection.
enum EpicKernelVariant: String, CaseIterable {
    case standard
    case noPostDagBarrier = "no-post-dag-barrier"

    static let productionDefault: EpicKernelVariant = .noPostDagBarrier
}

/// Fully-substituted Metal source for one prog_seed (useful for inspection and
/// for measuring compile time without going through Metal).
func epicKernelSource(progSeed: UInt64,
                      variant: EpicKernelVariant = EpicKernelVariant.productionDefault) throws -> String {
    guard let url = Bundle.module.url(forResource: "epic_kernel", withExtension: "metal.txt"),
          var src = try? String(contentsOf: url, encoding: .utf8) else {
        throw EpicKernelError.resourceMissing("epic_kernel.metal.txt")
    }
    let gen = generateKernelSource(progSeed: progSeed)
    src = src.replacingOccurrences(of: "INCLUDE_PROGPOW_RANDOM_MATH", with: gen.randomMath)
    src = src.replacingOccurrences(of: "INCLUDE_PROGPOW_DATA_LOADS",  with: gen.dataLoads)
    if variant == .noPostDagBarrier {
        src = "#define EPIC_EXPERIMENTAL_NO_POST_DAG_BARRIER 1\n" + src
    }
    return src
}

func compileEpicKernel(device: MTLDevice, progSeed: UInt64,
                       variant: EpicKernelVariant = EpicKernelVariant.productionDefault) throws -> MTLComputePipelineState {
    let src = try epicKernelSource(progSeed: progSeed, variant: variant)
    let opts = MTLCompileOptions()
    opts.languageVersion = .version2_4
    let lib: MTLLibrary
    do {
        lib = try device.makeLibrary(source: src, options: opts)
    } catch {
        throw EpicKernelError.compileFailed("\(error)")
    }
    guard let fn = lib.makeFunction(name: "epic_search") else {
        throw EpicKernelError.functionMissing("epic_search")
    }
    return try device.makeComputePipelineState(function: fn)
}
