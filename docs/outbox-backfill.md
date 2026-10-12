# Outbox baseline backfill

Before enabling TaskBridge Web publication for an existing deployment, seed the
local outbox with the current synchronized state:

```sh
bundle exec rake task_bridge:backfill_outbox DRY_RUN=1
bundle exec rake task_bridge:backfill_outbox
```

The dry run makes no writes and prints counts by source service, mapping
confidence, and incomplete records. The real run writes one baseline `item`
snapshot per complete source record and mapping rows only for high/medium
confidence memberships (`confirmed`/`inferred`). Low-confidence mappings are
withheld and counted for manual review. It never contacts or changes an
external source system, does not emit historical observation events or
sync-run rows, and is safe to run again: baseline timestamps and outbox
idempotency keys are stable.

After reviewing the dry run, run the real command, then enable normal outbox
publication using the configured TaskBridge Web endpoint.
