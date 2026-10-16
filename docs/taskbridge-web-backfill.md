# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication for an existing TaskBridge deployment, seed the local outbox with its current synchronized state:

```sh
bundle exec rake task_bridge:backfill_sync_provenance
```

Run the preview first. It makes no database or external-source changes. Its report groups planned item snapshots and skipped items (those without an external ID) by service, and eligible mappings by their `confirmed` or `inferred` confidence:

```sh
bundle exec rake task_bridge:backfill_sync_provenance -- --pretend
```

The backfill records each existing `sync_item` as one current-state `item` snapshot with `provenance.detected_by: backfill` and a `backfilled_at` timestamp. It deliberately does not create historical `observation` events or synthetic `sync_run` rows.

Membership mappings based on high-confidence sync IDs are published as `confirmed`; medium-confidence mappings, including title-derived matches, are published as `inferred`. Low-confidence mappings are withheld from the outbox for later manual cleanup or Web-side review.

The operation only reads local TaskBridge data and writes local provenance, baseline, and outbox records. It never calls or mutates an external provider. It is safe to rerun: existing baseline rows retain their deterministic idempotency keys.

After reviewing the dry-run output and completing the backfill, enable normal publication and run the publisher:

```sh
bundle exec rake task_bridge:outbox:publish
```
