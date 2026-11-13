import Foundation
import Metal

setbuf(stdout, nil)

// ===========================================================================
// epic-metal — Epic Cash ProgPoW 0.9.2 on Apple Metal.
//
// Subcommands
//   gpu-vectors     run the 12 official test vectors on the GPU (exit 0 = all pass)
//   dag-crosscheck  validate the GPU-built DAG + c_dag against the Rust oracle
//   device-info     print Metal device limits relevant to this kernel
//   gen-ops [h]     print the generated per-period program for block height h
//   dump-msl [f] [h]  write the fully expanded Metal source for height h to file f
//
// ===========================================================================

func usage() -> Never {
    print("""
    usage: epic-metal <command> [args]

      gpu-vectors            run the 12 official ProgPoW 0.9.2 vectors on the GPU
      dag-crosscheck         validate the GPU DAG and c_dag against the Rust oracle
      stratum-check ENDPOINT read and validate one Epic Stratum template; no mining/submission
      protocol-selftest     test full 256-bit Epic difficulty/target conversion
      statistics-selftest   test active/effective mining-time accounting
      mine ENDPOINT [options] mine consensus-selected ProgPow jobs; dry-run by default
                                --worker ID       worker identity (default epic-metal)
                                --password TEXT   Stratum password (default x)
                                --submit          enable share submission (default disabled)
                                --max-shares N    stop after N submissions; 0 = continuous
                                --stats SECONDS   status interval (default 15)
                                --duration SEC    stop after this duration (testing only)
                                --log LEVEL       quiet, normal (default), or verbose
                                --color MODE      auto (default), always, or never
                                --log-file PATH   write timestamped plain-text event log
      bench [options]        sustained GPU hashrate benchmark (real epoch, pre-validated)
                               --height N     block height (default 3795484, live tip)
                               --minutes F    run duration (default 10)
                               --groups N     threadgroups per dispatch (default 4096)
                               --threads N    threads per threadgroup (must be 256)
                               --header HEX   32-byte header hash
                               --target HEX   share target (default 0 = never wins)
                               --sample F     telemetry sample interval seconds (default 30)
                               --json FILE    write machine-readable results
                               --oracle PATH  Rust oracle binary for pre-flight vectors
                               --no-validate  skip the pre-flight known-answer check
      device-info            print Metal device limits
      gen-ops [height]       print the generated per-period program (default height 0)
      dump-msl [file] [height]  write expanded Metal source (default epic_kernel_expanded.metal)
    """)
    exit(2)
}

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "help"

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write("no Metal device available\n".data(using: .utf8)!)
    exit(1)
}

func heightArg(_ idx: Int) -> UInt64 {
    guard args.count > idx, let h = UInt64(args[idx]) else { return 0 }
    return h
}

do {
    switch command {
    case "gpu-vectors":
        let ok = try runEpicVectorTest(device: device)
        exit(ok ? 0 : 1)

    case "dag-crosscheck":
        let ok = try runEpicDagCrossCheck(device: device)
        exit(ok ? 0 : 1)

    case "stratum-check":
        guard args.count == 3 else { usage() }
        try runEpicStratumCheck(endpoint: args[2])
        exit(0)

    case "protocol-selftest":
        try runEpicProtocolSelfTest()
        exit(0)

    case "statistics-selftest":
        try runMiningStatisticsSelfTest()
        exit(0)

    case "mine":
        guard args.count >= 3 else { usage() }
        var worker = "epic-metal"
        var password = "x"
        var submit = false
        var maximumShares: Int?
        var statisticsInterval: TimeInterval = 15
        var duration: TimeInterval?
        var verbosity: EpicLogVerbosity = .normal
        var colorMode: EpicColorMode = .auto
        var logFile: String?
        var i = 3
        while i < args.count {
            switch args[i] {
            case "--worker":
                guard i + 1 < args.count else { usage() }
                worker = args[i + 1]
                i += 2
            case "--password":
                guard i + 1 < args.count else { usage() }
                password = args[i + 1]
                i += 2
            case "--submit":
                submit = true
                i += 1
            case "--max-shares":
                guard i + 1 < args.count, let value = Int(args[i + 1]), value >= 0 else { usage() }
                maximumShares = value == 0 ? nil : value
                i += 2
            case "--stats":
                guard i + 1 < args.count, let value = TimeInterval(args[i + 1]), value > 0 else { usage() }
                statisticsInterval = value
                i += 2
            case "--duration":
                guard i + 1 < args.count, let value = TimeInterval(args[i + 1]), value > 0 else { usage() }
                duration = value
                i += 2
            case "--log":
                guard i + 1 < args.count, let value = EpicLogVerbosity(rawValue: args[i + 1]) else { usage() }
                verbosity = value
                i += 2
            case "--color":
                guard i + 1 < args.count, let value = EpicColorMode(rawValue: args[i + 1]) else { usage() }
                colorMode = value
                i += 2
            case "--log-file":
                guard i + 1 < args.count else { usage() }
                logFile = args[i + 1]
                i += 2
            default:
                FileHandle.standardError.write("unknown mine option \(args[i])\n".data(using: .utf8)!)
                exit(2)
            }
        }
        if submit {
            FileHandle.standardError.write("WARNING: --submit enables live Stratum submissions. Confirm node/pool authorization before continuing.\n".data(using: .utf8)!)
        }
        let miningConfig = EpicMiningConfig(endpoint: args[2], worker: worker, password: password, submitShares: submit,
                                            maximumShares: maximumShares, statisticsInterval: statisticsInterval,
                                            duration: duration, verbosity: verbosity, colorMode: colorMode, logFile: logFile)
        try EpicMiningClient(device: device, config: miningConfig).run()
        exit(0)

    case "device-info":
        print("name:                        \(device.name)")
        print("maxThreadsPerThreadgroup:    \(device.maxThreadsPerThreadgroup)")
        print("maxThreadgroupMemoryLength:  \(device.maxThreadgroupMemoryLength) bytes")
        print("maxBufferLength:             \(device.maxBufferLength) bytes")
        print("recommendedMaxWorkingSet:    \(device.recommendedMaxWorkingSetSize) bytes")
        print("hasUnifiedMemory:            \(device.hasUnifiedMemory)")
        print("supportsFamily(.apple9):     \(device.supportsFamily(.apple9))")
        exit(0)

    case "bench":
        var cfg = EpicBenchConfig()
        var i = 2
        while i < args.count {
            switch args[i] {
            case "--height":  cfg.height = UInt64(args[i + 1])!; i += 2
            case "--minutes": cfg.minutes = Double(args[i + 1])!; i += 2
            case "--groups":  cfg.groups = UInt32(args[i + 1])!; i += 2
            case "--threads": cfg.threadsPerGroup = UInt32(args[i + 1])!; i += 2
            case "--header":  cfg.headerHex = args[i + 1]; i += 2
            case "--target":  cfg.targetHex = args[i + 1]; i += 2
            case "--sample":  cfg.sampleSeconds = Double(args[i + 1])!; i += 2
            case "--json":    cfg.jsonOut = args[i + 1]; i += 2
            case "--oracle":  cfg.oraclePath = args[i + 1]; i += 2
            case "--no-validate": cfg.skipValidation = true; i += 1
            default:
                FileHandle.standardError.write("unknown bench option \(args[i])\n".data(using: .utf8)!)
                exit(2)
            }
        }
        exit(Int32(try runEpicBenchmark(device: device, config: cfg)))

    case "gen-ops":
        let h = heightArg(2)
        let gen = generateKernelSource(progSeed: h / UInt64(EpicProgPow.PROGPOW_PERIOD))
        print("// block \(h) -> prog_seed \(h / UInt64(EpicProgPow.PROGPOW_PERIOD))")
        print(gen.randomMath)
        print(gen.dataLoads)
        exit(0)

    case "dump-msl":
        let file = args.count > 2 ? args[2] : "epic_kernel_expanded.metal"
        let h = heightArg(3)
        let src = try epicKernelSource(progSeed: h / UInt64(EpicProgPow.PROGPOW_PERIOD))
        try src.write(toFile: file, atomically: true, encoding: .utf8)
        print("wrote \(file) (\(src.count) bytes, prog_seed \(h / UInt64(EpicProgPow.PROGPOW_PERIOD)))")
        exit(0)

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
