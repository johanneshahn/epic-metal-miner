// swift-tools-version: 5.9
import PackageDescription

// Epic Cash ProgPoW 0.9.2 Metal implementation.
//
// Deliberately a separate package from `kawpow-mac` so the KawPow miner cannot
// regress: no file in kawpow-mac is modified by this package.
//
// Reused (verbatim) from kawpow-mac, which is GPLv3:
//   Sources/EpicMetal/Keccak.swift      keccak-f[1600], keccak-256/512 (ethash)
//   Sources/EpicMetal/Keccak800.swift   keccak-f[800] (ProgPoW permutation)
// Reused with Epic-specific constants:
//   Sources/EpicMetal/Ethash.swift      ethash sizing + light cache
//   Sources/EpicMetal/LightEval.swift   DAG item derivation (256 parents)
//   Sources/EpicMetal/DAG.swift         GPU DAG fill driver
// The two Metal sources are shipped with a `.metal.txt` extension on purpose.
// SwiftPM in Swift 6.x compiles any `.metal` file that lives under a target
// path, which fails here because the search kernel contains per-period
// placeholders that are only valid after substitution (and because both
// kernels are compiled from source at runtime anyway). Renaming them keeps
// SwiftPM from touching them while still shipping them as bundle data.
//
// Note: the upstream kawpow-mac package no longer builds on this toolchain for
// exactly this reason.
let package = Package(
    name: "epic-metal",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "epic-metal",
            path: "Sources/EpicMetal",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
