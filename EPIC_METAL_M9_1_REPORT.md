# Epic Metal Miner M9.1 report

## Hashrate discrepancy: root cause

M9 displayed two incompatible time windows under ambiguous labels. `Active`
was the recent status-window rate:

```text
recent completed hashes / recent active dispatch seconds
```

`Effective` was cumulative from process start:

```text
all completed hashes / complete monotonic session seconds
```

Therefore `13.10 MH/s × 46.1%` was not expected to reproduce a cumulative
5.00 MH/s effective rate: 13.10 was a recent interval, while 46.1% was a
cumulative utilization. This is a measurement-window mismatch, not a 17%
hash-accounting loss.

The dashboard now labels all three values explicitly:

- **Active (recent):** current status-window covered hashes / active dispatch
  seconds in that window.
- **Active (average):** total covered hashes / total active dispatch seconds.
- **Effective (session):** total covered hashes / full monotonic session time.

Only the latter two share the same cumulative numerator/time scope. They obey:

```text
Effective (session) = Active (average) × ProgPow active utilization
```

apart from display rounding. Active dispatch time includes command encoding and
the synchronous GPU completion wait; it excludes DAG/pipeline preparation,
non-ProgPow idle time, and reconnect wait. A completed batch is counted before
an incoming replacement job discards its candidate, so completed hashes are not
lost on a job transition.

## State and memory review

M9's current-period Metal pipeline and active-template duplicate-nonce bounds
remain correct. M9.1 also found a boundedness edge case: if a node never replied
to `status`, the old client created one new outstanding RPC map entry every 30
seconds. The client now permits only one outstanding status request and clears
it on reply or disconnect.

Completed job share records are retained only while a submission response is
outstanding. A delayed response is applied to that matching completed job, then
the record is released. This preserves job-level correctness across a template
transition without retaining session history indefinitely.

RSS remains process RSS, including the persistent shared DAG, Swift runtime,
and Metal/allocator pages; it is not a separate GPU-allocation measurement.
The previous one-hour run's 13.4 MiB RSS increase was not enough to identify a
root cause. Swift imports the IOReport sample dictionary with automatic Core
Foundation ownership, so an attempted manual release was correctly rejected;
there is no evidence for that proposed leak. Instruments provides both
Allocations and Metal System Trace templates for a follow-up capture if the
post-fix dry run does not plateau.

## Deterministic coverage

`statistics-selftest` now covers:

- preparation, reconnect, algorithm/no-work idle, and session shutdown;
- a recent 13.10 MH/s interval alongside cumulative 5.00 MH/s effective rate;
- the cumulative identity above;
- repeated ProgPow template refresh at the same height (not a new block).

The M9.1 60-minute no-submit run is in progress. Its final memory and
mathematical-consistency measurements will be appended after completion.
