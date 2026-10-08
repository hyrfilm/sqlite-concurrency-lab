# Measured example

This is one complete 288-run sweep on a Linux VM with Elixir 1.17.3, OTP 25,
SQLite 3.53.4 and four BEAM schedulers. It is not a measurement of a Nerves device.
Every transaction touches the same counter: this is a contention workload, not a
model of typical production traffic. Versions and settings are in
[environment.txt](example/environment.txt).

Across the sweep: **47,232 attempted writes, 36,600 committed writes, 4,966 SQLite
errors and 5,666 checkout errors**. There were also **807 failed reader calls**.
All 288 acknowledged-write audits passed. Saved error occurrence counts were
reconciled with every summary row. Exact rates vary between runs.

## Write failures

Each cell aggregates 12 runs (1/8/32 writers, 0/4 readers, two repeats), totaling
1,968 write attempts. Cells show **SQLite errors / checkout errors**. Read counts
and per-run error rates are in the raw data.

| Scenario | Pooled (5) | Single (1) | Writer + readers |
|---|---:|---:|---:|
| deferred | 1,546 / 0 | 0 / 0 | 0 / 0 |
| immediate | 0 / 0 | 0 / 0 | 0 / 0 |
| snapshot_window | 1,547 / 0 | 0 / 123 | 0 / 0 |
| immediate_window | 10 / 25 | 0 / 120 | 0 / 0 |
| no_busy_wait | 1,841 / 0 | 0 / 121 | 0 / 0 |
| slow_transactions | 22 / 875 | 0 / 1,115 | 0 / 0 |
| checkout_overload | 0 / 1,450 | 0 / 1,837 | 0 / 0 |
| full_sync | 0 / 0 | 0 / 0 | 0 / 0 |

The ordinary deferred pool failed even without a pause. Its matching immediate
baseline did not fail, but immediate mode still had failures with longer transaction
windows. One connection removed competing writers but still rejected checkouts.
Writer avoided failures in this sweep while its sampled mailbox reached 31 pending
messages and its longest successful caller latency was about 863 ms. These are
measurements under bounded worker counts, not proof of safe unbounded admission.

The separate tests held an external writer lock: **all three strategies failed all
eight attempted writes**, including Writer. Each then accepted a write after release.
Direct access also recovered after checkout overload. Test measurements are retained
in [test-output.txt](example/test-output.txt).

## Evidence

- [measurements.csv](example/measurements.csv): every run and its settings, latencies and resources.
- [errors.csv](example/errors.csv): every distinct observed exception/statement and occurrence count.
- [environment.txt](example/environment.txt): runtime and matrix.
- [test-output.txt](example/test-output.txt): focused failures and recovery checks.

Latency percentiles are bucket upper bounds. Memory and Writer mailbox peaks are
sampled every 50 ms and can miss spikes; memory excludes native SQLite allocations.
Readers loop freely, so read demand differs by topology. Temporary-file storage and
artificial pauses matter to interpretation; see the main README. No retries were used.
