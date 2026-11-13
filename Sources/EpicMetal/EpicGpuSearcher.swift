import Foundation
import Metal

struct EpicGpuCandidate {
    let nonce: UInt64
    let mixWords: [UInt32]
    let finalWords: [UInt32]
    let passedFullShareTarget: Bool
}

struct EpicGpuBatchResult {
    /// First nonce that was not fully processed. Resume here to avoid losing
    /// work after a 64-bit-prefilter false positive.
    let nextNonce: UInt64
    let hashesCovered: UInt64
    let candidate: EpicGpuCandidate?
}

struct EpicGpuPreparation {
    let rebuiltDAG: Bool
    let compiledProgram: Bool
}

/// Reusable production search path. It shares the verified `epic_search`
/// kernel with the benchmark and never uses a CPU hash fallback.
final class EpicGpuSearcher {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var dagEpoch: UInt64?
    private var dag: DAGOutput?
    // Only the current period can be dispatched. Retaining every historical
    // period's compiled pipeline is unnecessary and grows without bound.
    private var pipelineSeed: UInt64?
    private var pipeline: MTLComputePipelineState?
    // These shared buffers are reused across bounded dispatches. Reallocating
    // them for every nonce range needlessly added CPU/Metal-driver overhead to
    // the production loop.
    private let headerBuffer: MTLBuffer
    private let resultsBuffer: MTLBuffer
    private let resultIndexBuffer: MTLBuffer
    private let stopBuffer: MTLBuffer

    init(device: MTLDevice) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.headerBuffer = device.makeBuffer(length: 32, options: .storageModeShared)!
        self.resultsBuffer = device.makeBuffer(length: 64 * 4, options: .storageModeShared)!
        self.resultIndexBuffer = device.makeBuffer(length: 4, options: .storageModeShared)!
        self.stopBuffer = device.makeBuffer(length: 4, options: .storageModeShared)!
    }

    /// Drops retained DAG and compiled-program resources at shutdown. Metal
    /// releases the underlying allocations once outstanding command buffers
    /// have completed (search waits for each buffer before returning).
    func releaseResources() {
        dag = nil
        dagEpoch = nil
        pipeline = nil
        pipelineSeed = nil
    }

    func prepare(for job: EpicMiningJob) throws -> EpicGpuPreparation {
        var rebuiltDAG = false
        var compiledProgram = false
        if dagEpoch != job.epoch {
            print("[miner] building ProgPow epoch \(job.epoch) DAG")
            dag = try buildDAG(device: device, epoch: job.epoch)
            dagEpoch = job.epoch
            rebuiltDAG = true
        }
        if pipelineSeed != job.progSeed {
            pipeline = try compileEpicKernel(device: device, progSeed: job.progSeed)
            pipelineSeed = job.progSeed
            compiledProgram = true
        }
        return EpicGpuPreparation(rebuiltDAG: rebuiltDAG, compiledProgram: compiledProgram)
    }

    /// Search one contiguous nonce range. The kernel stops at the first
    /// top-64-bit prefilter match. The caller must resume at `nextNonce`, even
    /// when the full target rejects that candidate, to cover every nonce once.
    func search(job: EpicMiningJob, baseNonce: UInt64, groups: UInt32 = 4096) throws -> EpicGpuBatchResult {
        guard let dag, let pso = pipeline, pipelineSeed == job.progSeed else {
            throw EpicMiningError.malformedMessage("GPU searcher was not prepared")
        }
        let dagElements = dag.dagNumItems / 4
        _ = job.headerWords.withUnsafeBytes { source in
            memcpy(headerBuffer.contents(), source.baseAddress!, 32)
        }
        memset(resultsBuffer.contents(), 0, 64 * 4)
        memset(resultIndexBuffer.contents(), 0, 4)
        memset(stopBuffer.contents(), 0, 4)

        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setBuffer(dag.dag, offset: 0, index: 0)
        enc.setBuffer(headerBuffer, offset: 0, index: 1)
        enc.setBuffer(resultsBuffer, offset: 0, index: 2)
        enc.setBuffer(resultIndexBuffer, offset: 0, index: 3)
        enc.setBuffer(stopBuffer, offset: 0, index: 4)
        var nonce = baseNonce
        var target = job.shareTarget.gpuPrefilter
        var elements = dagElements
        var probe: UInt32 = 0
        var probeNonce: UInt64 = 0
        enc.setBytes(&nonce, length: 8, index: 5)
        enc.setBytes(&target, length: 8, index: 6)
        enc.setBytes(&elements, length: 4, index: 7)
        enc.setBytes(&probe, length: 4, index: 8)
        enc.setBytes(&probeNonce, length: 8, index: 9)
        enc.dispatchThreadgroups(MTLSize(width: Int(groups), height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw EpicKernelError.compileFailed("search dispatch: \(error)") }

        let range = UInt64(groups) * 256
        let claimed = resultIndexBuffer.contents().assumingMemoryBound(to: UInt32.self)[0]
        guard claimed > 0 else {
            return EpicGpuBatchResult(nextNonce: baseNonce &+ range, hashesCovered: range, candidate: nil)
        }
        let words = resultsBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let foundNonce = UInt64(words[0]) | (UInt64(words[1]) << 32)
        let mix = (0..<8).map { words[2 + $0] }
        let final = (0..<8).map { words[10 + $0] }
        let covered = foundNonce &- baseNonce &+ 1
        let candidate = EpicGpuCandidate(
            nonce: foundNonce,
            mixWords: mix,
            finalWords: final,
            passedFullShareTarget: job.shareTarget.accepts(finalWords: final)
        )
        return EpicGpuBatchResult(nextNonce: foundNonce &+ 1, hashesCovered: covered, candidate: candidate)
    }
}
