# Epic Cash Metal Miner

Native macOS Epic Cash **ProgPow-only** miner for Apple Metal GPUs. It uses
Epic's built-in newline-delimited JSON-RPC Stratum protocol and never falls
back to CPU mining or another proof-of-work algorithm.

## Status and safety

- Official ProgPow 0.9.2 GPU vectors: **12/12 pass**.
- Mainnet integration: controlled shares have been accepted by an Epic node.
- Mining is dry-run by default. `--submit` is required to send a share.
- Only a template whose returned `algorithm` is exactly `progpow` is mined.
  RandomX, Cuckoo, and unknown jobs safely idle the miner.

## Build

Requirements: macOS 13+, Xcode/Metal command-line tools, and Swift 5.9+.

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
# Continuous, no-submit validation run
.build/release/epic-metal mine HOST:PORT --worker my-mac

# A one-hour dry-run with 30-second statistics
.build/release/epic-metal mine HOST:PORT --worker my-mac --duration 3600 --stats 30

# Live shares — only on an endpoint you are authorized to use
.build/release/epic-metal mine HOST:PORT --worker my-mac --submit
```

Use `Ctrl-C` or `SIGTERM` to stop. The miner closes its socket, releases its
retained DAG/pipeline resources, and prints final counters.

Never use `--submit` against a node or pool without authorization. A node can
select any Epic algorithm for a height, so passing `progpow` to
`getjobtemplate` does not reserve a ProgPow job.

## Mining configuration

| Option | Default | Meaning |
|---|---:|---|
| `ENDPOINT` | required | `HOST:PORT` Epic Stratum endpoint |
| `--worker ID` | `epic-metal` | Stratum worker identity |
| `--password TEXT` | `x` | Stratum password required by the selected endpoint |
| `--submit` | off | Send locally valid shares |
| `--max-shares N` | unlimited | Stop after N submitted shares; `0` means unlimited |
| `--stats SECONDS` | `15` | Periodic status interval |
| `--duration SEC` | unlimited | Stop after a controlled test duration |
| `--log LEVEL` | `normal` | `quiet`, `normal`, or `verbose` |
| `--color MODE` | `auto` | `auto`, `always`, or `never`; auto honors `NO_COLOR` |
| `--log-file PATH` | none | Timestamped plain-text event log; parent directory is created |

The status line reports dispatch-measured current and average hashrate,
IOReport GPU power and MH/s/W when macOS exposes them, OS-reported resident
memory, current height/epoch/share difficulty, and share/reconnect counters.
Unavailable telemetry is printed as `unavailable`; it is never estimated.
Active hashrate is measured only over completed ProgPow GPU dispatches.
Effective hashrate divides completed hashes by full monotonic session time,
including DAG preparation, reconnects, and non-ProgPow idle time.

The dashboard reports `This job` counters for full-target-valid ProgPow shares
found on the active template, plus the completed previous-job summary. Use
these measured counts—not a nominal hash rate—to tune a node's minimum share
difficulty. One share per job is a probabilistic target, not a guarantee.

`ProgPow blocks` counts distinct consensus-selected ProgPow heights observed
in the session, not template refreshes. `Accepted/block` and `Found/block`
are session averages divided by that count.

See `EPIC_METAL_M9_REPORT.md` for memory-lifetime findings, terminal behavior,
and the statistics definitions.

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
