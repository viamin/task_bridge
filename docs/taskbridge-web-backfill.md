# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication, seed the local outbox with the
current synchronized state:

```sh
bundle exec rake task_bridge:backfill_sync_provenance_dry_run
bundle exec rake task_bridge:backfill_sync_provenance
```

The dry run does not write TaskBridge data or contact any external service. It
prints JSON counts by source service and mapping confidence, including skipped
incomplete records and low-confidence mappings withheld from publication.

The write task only updates local provenance and creates durable outbox rows.
It never mutates a source system. It creates one baseline `item` snapshot per
known item (no historical `snapshot_seen` observations), and mapping rows only
for high/confirmed and medium/inferred memberships. Low/tentative memberships
remain visible in dry-run output for manual cleanup.

Backfill timestamps come from the existing local observation/update timestamps,
so idempotency keys and baseline payloads are stable across reruns. After
reviewing the dry-run counts, run the write task, then enable publication and
use `bundle exec rake task_bridge:outbox:publish`.
