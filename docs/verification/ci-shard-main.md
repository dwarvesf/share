# Verification -- ci-shard-main

A push to main now runs the suite as the same shards a PR uses (`tests/ci/shards.txt`), on Ubuntu and macOS in parallel. Before, main ran the whole suite unsharded per OS, and macOS took 23 to 30 minutes.

## Green run
```
Command: bash tests/ci/shard-check.sh
Exit: 0
Output:
shard-check: 86 sections, 3 shards, each section in exactly one
Verdict: PASS (the three shards together run every section once, so the sharded main run covers the whole suite)
```
PR CI already runs each shard on Ubuntu, and `members-b` on macOS (run 44548041393: chain 12m, members-a 9m, members-b 4m, macOS members-b 7m). Section totals from that run: chain 1085 s, members-a 874 s, members-b 326 s on Ubuntu; macOS runs the same sections about 1.8 times slower.

## Negative control
```
Command: bash tests/ci/shard-check-test.sh
Exit: 0
Output:
        shard-check: 2 shards run section: members: member rm and member purge (TASK-2d) (members-a members-b)
  ok    a shard that names no section turns it red (exit 1)
Verdict: PASS (a section in two shards, or a shard naming nothing, turns the check red)
```

## Not proven
- The first sharded main run's wall time, and macOS `chain` finishing under the 45 minute limit; read the next main run's test-full jobs.
