# Epic Metal Miner M9.5 report

## Dashboard behaviour

Interactive terminals now redraw the existing dashboard once per second by
default. `--stats SECONDS` remains an explicit interactive refresh override.
Redirected output keeps the existing 15-second line-oriented statistics cadence,
so dashboard redraws do not produce one log entry per second.

The renderer now has valid waiting and reconnecting states even when no ProgPow
job is active. It retains cursor restore behaviour and redraws only its own
dashboard region; no full-screen clear or mining-thread timer was introduced.

## Current work and activity

`CURRENT WORK` identifies connection, selected algorithm, block height, pool
job ID, assigned share difficulty, state, and uptime. It never presents an
unsupported or disconnected job as actively hashing.

The title independently labels `LIVE MINING` when `--submit` is enabled and
`DRY RUN` otherwise. Share counters explicitly distinguish found, submitted,
accepted, rejected, and stale shares.

Activity history is bounded to four entries, newest-first, tab/newline
normalised and width-clipped. The newest line receives a bright cyan highlight
when colour is enabled. Compact messages use job/share summaries; verbose logs
retain the technical detail.

## Validation

- `swift build -c release`: PASS
- `statistics-selftest`: PASS
- `protocol-selftest`: PASS
- official GPU vectors: 12/12 PASS
- a no-submit pseudo-TTY pool run confirmed one-second waiting-state redraws,
  dry-run labelling, cursor restoration, and no submissions.

No Metal kernel, consensus, share-target, or Stratum protocol change was made.
