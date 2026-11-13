# Epic Metal Miner M9 report

## Memory investigation

The prior `memory` field is macOS process resident set size (RSS), obtained
from `ps -o rss`. On Apple Silicon it is not a dedicated GPU-memory number:
it includes Swift/Foundation allocations, code/data pages, Metal shared
buffers, and allocator/driver-retained pages. The current ProgPow DAG alone
is about 2.0 GiB and is deliberately retained for the active epoch.
Consequently an RSS near 2.1 GiB after DAG creation is expected and does not
itself prove a leak.

The observed gradual increase (about 8 MiB across half an hour) could not be
attributed to an allocation trace while a user-authorized live miner was
running, so M9 does not claim that it has eliminated an RSS leak. Two real
unbounded host-retention paths were found by ownership inspection and fixed:

- The former pipeline dictionary retained every compiled ProgPow period. The
  searcher now retains only the current period's pipeline.
- The former duplicate-submission set retained a string for every submitted
  share for process lifetime. It now retains nonce values only for the active
  template and clears at the same generation boundary that makes old work stale.

Outstanding RPC IDs are also cleared when a connection is discarded. Jobs,
templates and command buffers have bounded lifetimes: the active template is
replaced on each job; batches synchronously wait for command completion; DAGs
are retained only by epoch and released at shutdown. Statistics and logs do
not retain historical records in memory.

## Statistics definitions

- **Active hashrate** = completed hashes / measured ProgPow GPU dispatch time.
- **Effective hashrate** = completed hashes / full monotonic session time.
- **ProgPow active time** includes completed GPU dispatches only.
- **Preparation time** covers DAG/pipeline work and is excluded from active
  hashing; **reconnect time** covers retry delay; remaining time is
  algorithm/no-work idle time.

GPU power is IOReport GPU-only power, not system power. Efficiency is omitted
for a status window with less than 80% active dispatch coverage.

`statistics-selftest` deterministically covers startup preparation, active
hashing, reconnect time, algorithm idle time and session-end accounting.

## Terminal and logging

Interactive TTY output is a compact refreshing dashboard. Non-TTY output is
plain text. ANSI color is controlled by `--color auto|always|never`; `auto`
requires a TTY and honors `NO_COLOR`. `--log-file PATH` creates parent
directories and writes timestamped, uncolored event records suitable for
parsing. Repeated templates at the same algorithm/height are verbose-only;
normal events report meaningful state transitions and share outcomes.

## Verification status

- Clean build, `protocol-selftest`, and `statistics-selftest` pass after M9
  changes. The official Metal GPU vectors remain 12/12 PASS.
- Redirected-output checks passed: `--color auto` emitted no ANSI sequences in
  stdout or `--log-file`; an explicit `--color always` affects stdout only,
  never the persistent log.
- A no-submit M9 60-minute local-node dry-run is in progress. Its final
  telemetry and RSS observations will be appended when it exits.

## Remaining limitation

RSS is the process-level stability indicator available without a privileged
Metal allocation profiler, but it cannot separate driver allocator caching from
application-owned Metal pages. The pending post-M9 dry-run should record RSS
immediately after DAG creation and at shutdown; persistent material growth
after these bounded-retention fixes would justify an Instruments Allocations or
Metal System Trace capture.
