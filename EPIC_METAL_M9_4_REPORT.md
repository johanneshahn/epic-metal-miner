# Epic Metal Miner M9.4 report

## Share statistics

The compact dashboard now shows locally found, full-256-bit-valid ProgPow shares per observed ProgPow block and per distinct ProgPow job. Submitted and accepted shares remain separate counters. Jobs are distinct non-identical ProgPow templates; exact duplicate notifications retain the active nonce range and do not restart GPU work. Blocks are distinct observed ProgPow heights, so template refreshes are not counted as blocks. RandomX and Cuckoo jobs are never included.

All session averages include the currently active, partially observed job and block. This avoids hiding work at startup or shutdown. Accounting persists across reconnects for the life of the process.

## Expected-share method

Epic's share boundary is `floor((2^256 - 1) / difficulty)`. A uniformly distributed 256-bit digest has probability `(floor((2^256 - 1) / difficulty) + 1) / 2^256` of being a share, which is `1 / difficulty` to displayed precision. The miner sums `covered hashes / share difficulty` for every completed GPU interval, so share-difficulty changes are weighted independently. Detailed mode exposes the result as `Expected / block`; it is a statistical expectation, not a target or a difficulty control.

## Hashrate investigation

The M9.1 no-submit run ended early after 40:11 because the local node disconnected, temporarily refused connections, and reported that it was syncing. It covered 5,229,969,718 hashes with 7.38 MH/s active average, 2.17 MH/s effective session, and 29.4% ProgPow time. The cumulative identity holds: `7.38 × 0.294 ≈ 2.17`. It made zero submissions.

The run showed live active intervals of approximately 6.1–6.7 MH/s as well as short intervals near 11.8–12.9 MH/s. Controlled, validated, one-minute benchmarks on the same Apple M4 Pro used the miner's 4,096 × 256 dispatch geometry and one in-flight command buffer:

| Workload | Rate | GPU power | GPU utilisation |
| --- | ---: | ---: | ---: |
| continuous seed 75909 | 12.89 MH/s | 35.63 W | 97% |
| continuous affected seed 75930 | 11.83 MH/s | 37.47 W | 99% |

Both benchmarks passed exact-height oracle pre-flight validation. The one-in-flight affected-seed result rules out the Metal kernel, DAG rebuild, pipeline compilation, and synchronous completion wait as the source of the approximately 6 MH/s live readings. The remaining difference is specific to the interrupted live Stratum workload (template transitions/no-work periods and measurement timing), not a confirmed raw-GPU regression. No kernel or consensus change was made.

## UI and validation

Activity messages are now concise (`Mining started · Block #…`, `Waiting · RandomX block`, and `Share accepted`); verbose logs preserve diagnostics. Session-average GPU power and efficiency are explicitly labelled separately from recent-window values.

Validation after the dry run: release build PASS, statistics self-test PASS, protocol self-test PASS, and official Metal vectors 12/12 PASS. The statistics self-test covers multiple jobs in one block, multiple and zero-share jobs, partial jobs/blocks, a target change, repeated template/block notifications, and cumulative hashrate accounting. Live share submission remained disabled.

## Limitations

Block identity is the consensus-selected observed ProgPow height; a deep same-height chain reorganisation cannot be distinguished from a refresh by the available Stratum template fields. Process RSS is not a GPU allocation metric; the short interrupted run is insufficient to attribute its small RSS movement.
