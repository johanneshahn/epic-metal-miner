import Foundation

/// Read-only endpoint check used by M4 and by future integration tests. It
/// authenticates (when a worker name is provided), requests a template and
/// validates the wire representation. It never dispatches GPU work or submits.
func runEpicStratumCheck(endpoint: String, worker: String = "epic-metal-audit") throws {
    let socket = EpicStratumSocket()
    try socket.connect(endpoint: endpoint)
    defer { socket.close() }

    let loginID = "audit-login"
    try socket.sendJSON(epicRPCRequest(
        id: loginID,
        method: "login",
        params: ["login": worker, "pass": "", "agent": "epic-metal/m4-audit"]
    ))
    _ = try awaitResponse(socket, id: loginID)

    let templateID = "audit-template"
    try socket.sendJSON(epicRPCRequest(
        id: templateID,
        method: "getjobtemplate",
        params: ["algorithm": EpicAlgorithm.progpow.rawValue]
    ))
    let message = try awaitResponse(socket, id: templateID)
    guard let result = message["result"] else {
        throw EpicMiningError.malformedMessage("getjobtemplate response lacks result")
    }
    let template = try decodeEpicTemplate(result)
    let prePow = try template.validatedPrePow()

    print("=== Epic Stratum protocol check ===")
    print("endpoint: \(endpoint)")
    print("height: \(template.height)  job_id: \(template.jobID)  algorithm: \(template.algorithm)")
    print("pre_pow: \(prePow.count) bytes")
    print("difficulty: \(template.difficulty.map { "\($0.algorithm)=\($0.value)" }.joined(separator: ", "))")
    print("block_difficulty: \(template.blockDifficulty.map { "\($0.algorithm)=\($0.value)" }.joined(separator: ", "))")
    if template.algorithm == EpicAlgorithm.progpow.rawValue {
        let job = try EpicMiningJob(generation: 1, template: template)
        print("ProgPow: supported; epoch \(job.epoch), prog_seed \(job.progSeed), share target \(String(format: "%016llx", job.shareTarget.gpuPrefilter))")
    } else {
        print("ProgPow: idle (server selected unsupported \(template.algorithm) work)")
    }
    print("submission: not attempted")
}

private func awaitResponse(_ socket: EpicStratumSocket, id: String) throws -> [String: Any] {
    while true {
        let message = try socket.readJSONLine()
        if let method = message["method"] as? String, method == "job" {
            // A broadcast can race an ordinary response. It is deliberately
            // ignored by this one-shot audit, but the production controller
            // will process it as a replacement job.
            continue
        }
        guard String(describing: message["id"] ?? "") == id else { continue }
        if let error = message["error"], !(error is NSNull) {
            throw EpicMiningError.malformedMessage("RPC \(id) failed: \(error)")
        }
        return message
    }
}
