# Epic Metal Miner M9 report

## Memory investigation

The prior `memory` field is macOS process resident set size (RSS), obtained
from `ps -o rss`. On Apple Silicon it is not a dedicated GPU-memory number:
it includes Swift/Foundation allocations, code/data pages, Metal shared
buffers, and allocator/driver-retained pages. The current ProgPow DAG alone
is about 2.0 GiB and is deliberately retained for the active epoch.
Consequently an RSS near 2.1 GiB after DAG creation is expected and does not
itself prove a leak.

The observed gradual increase could not be attributed to an allocation trace,
so M9 does not claim that it has eliminated an RSS leak. Two real
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
- A no-submit M9 60-minute local-node dry-run completed. Results follow.

## 60-minute dry-run result

The miner ran for exactly 60 minutes with `--submit` omitted. It completed
11,492,879,719 covered nonce hashes. Measured active ProgPow time was 47.2%
(about 1,699 seconds), yielding 6.77 MH/s active and 3.19 MH/s effective over
the entire hour. The gap is real session behavior: inactive consensus-selected
algorithms, bounded candidate dispatches, and node interruptions are included
in effective time and excluded from active time.

| Measurement | Result |
|---|---:|
| Algorithm/no-work idle | 1,753.1 s |
| DAG/program preparation | 3.4 s |
| Reconnect delay | 145.1 s |
| Reconnects | 29 |
| Submitted / accepted / rejected / stale / unknown | 0 / 0 / 0 / 0 / 0 |
| GPU errors | none reported |

The node restarted/synchronized during the run, accounting for the reconnect
time. Its configured share difficulty also changed from 200,000,000 to
126,000,000 and then 120,000,000; dry-run mode did not submit any resulting
candidate.

RSS was 2,115.5 MiB shortly after DAG setup and 2,128.9 MiB near completion,
a 13.4 MiB increase. The one epoch DAG remained stable; the two known unbounded
application collections had already been bounded. Swift automatic management
also confirms the IOReport sample dictionaries are not manually releasable.
This remaining small RSS slope is therefore **unattributed**, not claimed fixed.
An Instruments Allocations + Metal System Trace capture is the next appropriate
step if it persists in a post-M9 comparison run.

## Remaining limitation

RSS is the process-level stability indicator available without a privileged
Metal allocation profiler, but it cannot separate driver allocator caching from
application-owned Metal pages. The pending post-M9 dry-run should record RSS
immediately after DAG creation and at shutdown; persistent material growth
after these bounded-retention fixes would justify an Instruments Allocations or
Metal System Trace capture.
