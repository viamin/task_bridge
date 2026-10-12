# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication, seed the local outbox with the
current synchronized state:

```sh
bundle exec rake task_bridge:backfill_outbox_baseline DRY_RUN=1
bundle exec rake task_bridge:backfill_outbox_baseline
```

The dry run makes no database changes and prints item counts by service,
mapping counts by confidence, and skipped/incomplete records. Review it before
the live command.

The live command first fills missing local source provenance, then creates one
baseline `item` snapshot per existing synchronized item and mapping rows for
`high`/confirmed and `medium`/inferred memberships. Baseline item payloads are
marked with `provenance.detected_by: backfill` and `backfilled_at`; they do not
create `snapshot_seen`, source-change, or sync-run events.

Low-confidence (`low`/tentative) memberships are deliberately withheld from
publication. Their count remains visible in dry-run output for manual cleanup
or later review. The task never contacts or mutates external source systems.

The outbox's deterministic idempotency keys make live reruns safe. Existing
rows are reused, so it is also safe to rerun after an interrupted execution.
