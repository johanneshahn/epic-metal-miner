# Phase 2 — Production integration of `no-post-dag-barrier`

**Date:** 2026-11-14
**Decision applied:** the explicitly approved controlled production integration.
**Production default:** `no-post-dag-barrier`.

## Files changed for this integration

- `Sources/EpicMetal/EpicKernel.swift` — defines the production default once
  as `EpicKernelVariant.productionDefault`.
- `Sources/EpicMetal/EpicMiningClient.swift` — stores the selected immutable
  variant in mining configuration and reports it in startup logs.
- `Sources/EpicMetal/EpicGpuSearcher.swift` — receives that variant at
  construction and uses it whenever it compiles a new period pipeline.
- `Sources/EpicMetal/main.swift` — adds `mine --kernel NAME`, validates its
  value, and makes the new default visible in help text.
- `Sources/EpicMetal/EpicBench.swift` — aligns the benchmark's no-option
  default with the production default; explicit choices are unchanged.
- `README.md` — documents the default, measured performance result, rollback,
  and energy-efficiency limitation.

No Metal kernel source, ProgPoW calculation, DAG/c_dag construction, nonce
allocation, share/target checking, protocol handling, job cancellation,
batch size, or GPU dispatch topology was changed.

## Kernel selection and rollback

The selected value is part of `EpicMiningConfig` and is passed once to
`EpicGpuSearcher`. It is retained for the full mining session and used at
pipeline compilation for each new ProgPoW period. There is no automatic or
silent fallback: a Metal compilation error propagates to the existing mining
error/reconnect reporting path. A selection therefore cannot change between
jobs without restarting the process.

| Invocation | Active kernel |
|---|---|
| `epic-metal mine HOST:PORT ...` | `no-post-dag-barrier` |
| `epic-metal mine HOST:PORT --kernel no-post-dag-barrier ...` | `no-post-dag-barrier` |
| `epic-metal mine HOST:PORT --kernel standard ...` | original `standard` fallback |

Invalid values are rejected before the client starts, for example:

```text
invalid kernel variant 'invalid-kernel'; expected no-post-dag-barrier or standard
```

The startup event logs the exact immutable choice:

```text
INFO  MINER    ProgPow kernel variant: no-post-dag-barrier
```

To roll back without rebuilding, restart mining with:

```sh
.build/release/epic-metal mine HOST:PORT --worker my-mac --kernel standard
```

## Validation performed after integration

The release binary was rebuilt and these checks passed:

| Check | Result |
|---|---|
| `swift build -c release` | PASS |
| `protocol-selftest` | PASS |
| `statistics-selftest` | PASS |
| `dag-crosscheck` (epochs 0 and 1, DAG and c_dag fingerprints) | PASS |
| `gpu-vectors --kernel standard` | 12/12 PASS |
| `gpu-vectors --kernel no-post-dag-barrier` | 12/12 PASS |
| Invalid `mine --kernel invalid-kernel` | clear error, exit 2 |
| No-option production startup | logs `no-post-dag-barrier` |
| Explicit `mine --kernel standard` startup | logs `standard` |
| Explicit `mine --kernel no-post-dag-barrier` startup | logs `no-post-dag-barrier` |

The production-start checks used `127.0.0.1:1`, `--dry-run`, and a short
duration. They deliberately made no network submission or protocol change;
the expected connection refusal occurred only after the startup log. This
tests CLI parsing, configuration propagation, and immutable selection, not a
real job dispatch.

The available independent Rust oracle was used for post-integration
exact-height checks at height 3,795,484 (epoch 126):

| Variant | DAG elements | c_dag fingerprint | Mix/final | Result |
|---|---:|---|---|---|
| no option (production default: `no-post-dag-barrier`) | 8,323,049 | `c8e4dede` / `9a7d82d6` | PASS / PASS | PASS (`oracle@3795484`) |
| `standard` | 8,323,049 | `c8e4dede` / `9a7d82d6` | PASS / PASS | PASS (`oracle@3795484`) |

The default artifact is
`benchmark-results/phase2-production-integration-2026-11-14/default-exact-height.json`;
the standard artifact is
`benchmark-results/phase2-production-integration-2026-11-14/standard-exact-height.json`.
The same post-integration oracle preflight also passed at height 0 for both
variants (the two JSON files in `multiepoch/`). The complete eight-height,
two-kernel reference corpus remains in
`benchmark-results/phase2-production-readiness/multiepoch/`; it was created
before this selection-only integration, and neither the Metal source nor the
explicit-variant reference path changed here.

## Benchmark teardown limitation discovered during validation

Short `bench` invocations write their complete PASS result/JSON, then exit
with SIGTRAP (133) on this host. The macOS crash report identifies an existing
benchmark-only teardown problem in `runEpicBenchmark`:

```text
BUG IN CLIENT OF LIBDISPATCH: Semaphore object deallocated while in use
```

It occurred for both kernel variants, including `--no-validate`, and after
the benchmark printed all results. `device-info`, the self-tests, DAG
crosscheck, GPU vectors, and production-start checks exit normally. This is
not a hash mismatch or a production-miner failure, and it predates / is
outside the selection-only scope of this integration; no unrelated benchmark
refactor was made. It should be repaired and regression-tested separately
before treating short benchmark process exit status as automation-ready.

## Performance and limitations

The basis for this controlled rollout remains the six paired 8,192-group
measurements in `METAL_PHASE2_PRODUCTION_READINESS.md`: mean hashrate improved
by 0.2908 MH/s (+2.13%; paired 95% CI +0.2114 to +0.3702), and GPU dispatch
time fell by 3.212 ms (−2.09%; paired 95% CI −4.132 to −2.292). These are
kernel-variant results, not promises of a session-average gain.

GPU-energy efficiency remains unconfirmed. The paired J/MH result was +0.0039
J/MH with a 95% CI of −0.0493 to +0.0570, which includes no difference. GPU
power telemetry excludes total system power. The earlier transient GPU
performance-state behavior also remains unexplained; the selected kernel does
not attempt to manage or mask it.

No real mining smoke test with a valid job was performed: no authorized
endpoint/job was supplied for this task, and the project documentation forbids
mining against an endpoint without authorization. The local startup smoke
tests and all correctness tests above are the furthest safe validation in this
environment.
