# Epic Cash Metal Miner

Native macOS Epic Cash **ProgPow-only** miner for Apple Metal GPUs. It uses
Epic's built-in newline-delimited JSON-RPC Stratum protocol and never falls
back to CPU mining or another proof-of-work algorithm.

## Status and safety

- Official ProgPow 0.9.2 GPU vectors: **12/12 pass**.
- Mainnet integration: three controlled, authorized shares were accepted by a
  local Epic node; details are in `EPIC_METAL_PROGRESS.md`.
- Mining submits valid shares by default. Use `--dry-run` for local-only
  validation without submissions.
- Only a template whose returned `algorithm` is exactly `progpow` is mined.
  RandomX, Cuckoo, and unknown jobs safely idle the miner.

## Build

Requirements: macOS 13+, Xcode/Metal command-line tools, and Swift 5.9+.

### First-time macOS setup

You do **not** need to install Swift separately. Apple ships Swift and the
Metal compiler with the Xcode Command Line Tools. In Terminal, install them:

```sh
xcode-select --install
```

Complete the macOS installer dialog, then verify the tools are available:

```sh
swift --version
xcrun --find metal
```

If either command fails after installation, restart Terminal and run the
commands again. A Metal-capable Apple Silicon Mac and macOS 13 or newer are
required. This project currently builds from source; it does not provide a
prebuilt binary release.

```sh
swift build -c release
```

The binary is `.build/release/epic-metal`.

## Verify before mining

```sh
.build/release/epic-metal protocol-selftest
.build/release/epic-metal gpu-vectors
.build/release/epic-metal stratum-check HOST:PORT
```

`stratum-check` logs in and reads one template only; it does not hash or
submit.

## Mining

```sh
# Continuous live mining — only on an endpoint you are authorized to use
.build/release/epic-metal mine HOST:PORT --worker my-mac

# A one-hour dry-run with 30-second statistics
.build/release/epic-metal mine HOST:PORT --worker my-mac --dry-run --duration 3600 --stats 30

# `--submit` is accepted for compatibility; it is already the default
.build/release/epic-metal mine HOST:PORT --worker my-mac --submit
```

Use `Ctrl-C` or `SIGTERM` to stop. The miner closes its socket, releases its
retained DAG/pipeline resources, and prints final counters.

Never mine against a node or pool without authorization. Use `--dry-run` when
testing locally. A node can
select any Epic algorithm for a height, so passing `progpow` to
`getjobtemplate` does not reserve a ProgPow job.

## Mining configuration

| Option | Default | Meaning |
|---|---:|---|
| `ENDPOINT` | required | `HOST:PORT` Epic Stratum endpoint |
| `--worker ID` | `epic-metal` | Stratum worker identity |
| `--password TEXT` | `x` | Stratum password; MineFleet specifies `x` |
| `--submit` | on | Send locally valid shares (compatibility option) |
| `--dry-run` | off | Find locally valid shares without submitting them |
| `--max-shares N` | unlimited | Stop after N submitted shares; `0` means unlimited |
| `--stats SECONDS` | `15` | Periodic status interval |
| `--duration SEC` | unlimited | Stop after a controlled test duration |
| `--log LEVEL` | `normal` | `quiet`, `normal`, or `verbose` |
| `--color MODE` | `auto` | `auto`, `always`, or `never`; `NO_COLOR` disables auto color |
| `--dashboard MODE` | `compact` | Interactive `compact` or `detailed` dashboard |
| `--log-file PATH` | none | Timestamped plain-text event log; parent directory is created |

The status line reports dispatch-measured current and average hashrate,
IOReport GPU power and MH/s/W when macOS exposes them, OS-reported resident
memory, current height/epoch/share difficulty, and share/reconnect counters.
Unavailable telemetry is printed as `unavailable`; it is never estimated.
`Active` hashrate is measured only over completed ProgPow GPU dispatches.
`Effective` hashrate divides the same completed hashes by the full monotonic
session duration, including DAG preparation, reconnects and non-ProgPow idle.
When stdout is interactive, a compact dashboard refreshes at the statistics
interval; redirected output remains plain text without ANSI escapes.

### Dashboard modes

The default compact dashboard emphasizes the recent active hashrate, effective
session rate, GPU power, mining time, connection state, share totals, and four
recent meaningful events. Use `--dashboard detailed` for process RSS, epoch,
total hashes, active/idle/preparation/reconnect time, shares-per-block, and
per-job diagnostics. Both dashboards automatically use a narrow layout below
72 terminal columns.

Representative compact view:

```text
  EPIC METAL MINER                                      ● MINING
  Apple Silicon · Metal GPU
  ───────────────────────────────────────────────────────────

                   13.10 MH/s
                   ACTIVE HASHRATE (RECENT)

  Effective session  5.00 MH/s
  Active average    10.85 MH/s
  GPU power          29.8 W
  Efficiency         0.44 MH/s/W
  ProgPow time       46.1%
```

Compact mode displays locally valid `Shares / ProgPow block` and `Shares / job`.
Both include partially observed current jobs/blocks. Detailed mode adds the
target-weighted expected shares per block: the sum of `covered hashes / share
difficulty` for each observed job.

`Found` means a locally verified full-target ProgPow share. It is distinct from
shares submitted to, or accepted by, the endpoint. `ProgPow block` means a
distinct observed consensus-selected ProgPow height, not a 15-second template
refresh; unsupported algorithms are excluded. These are session averages and
are probabilistic monitoring values, not difficulty controls.

In an interactive terminal, the compact dashboard refreshes once per second by
default. `--stats SECONDS` overrides that refresh interval. Redirected output
stays line-oriented at the normal statistics cadence and never contains ANSI
dashboard control sequences.

## Troubleshooting

- **`idle` / RandomX or Cuckoo:** normal. The node selected a different
  consensus algorithm; wait for a new ProgPow job.
- **Connection retry:** check endpoint/firewall/node status. The client
  invalidates the prior template, waits five seconds, logs in, and requests a
  fresh job.
- **Stale response:** the node replaced the job before submission. Do not
  retry that nonce; the client discards it and mines the current job.
- **No GPU power:** the private macOS IOReport `GPU Energy` channel is not
  available on this system. Hashing remains valid; power is reported as
  unavailable.
- **Build failure:** install current Xcode command-line tools and verify a
  Metal-capable Apple GPU is present with `device-info`.

## Licensing

This package is distributed under GPL-3.0. See `LICENSE` and `NOTICE` for
license terms, source provenance, and redistribution obligations. The complete
corresponding source required to build the miner is present in this repository.
