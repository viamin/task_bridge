# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication for an existing TaskBridge deployment, preview the local outbox backfill first. It makes no database or external-source changes. Its report groups planned item snapshots and skipped items (those without an external ID) by service, and eligible mappings by their `confirmed` or `inferred` confidence — including mappings whose confidence the provenance backfill is about to infer for collections that do not carry mapping labels yet:

```sh
bundle exec rake task_bridge:backfill_sync_provenance -- --pretend
```

After reviewing the preview, seed the local outbox with its current synchronized state:

```sh
bundle exec rake task_bridge:backfill_sync_provenance
```

The backfill records each existing `sync_item` as one current-state `item` snapshot with `provenance.detected_by: backfill` and a `backfilled_at` timestamp. It deliberately does not create historical `observation` events, synthetic `sync_run` rows, or deletion tombstones: disappearances are detected and published by `Disappearance::Detector` during a live sync, and re-seeding local rows is not a new observation of the source. Any disappearance already recorded in `sync_item.source_metadata` is preserved rather than consumed, so the next detection does not re-publish the same tombstone as a new fact.

Membership mappings based on high-confidence sync IDs are published as `confirmed`; medium-confidence mappings, including title-derived matches, are published as `inferred`. Low-confidence mappings are withheld from the outbox for later manual cleanup or Web-side review.

The operation only reads local TaskBridge data and writes local provenance, baseline, and outbox records. It never calls or mutates an external provider. It is safe to rerun: existing baseline rows retain their deterministic idempotency keys.

After reviewing the dry-run output and completing the backfill, enable normal publication and run the publisher:

```sh
bundle exec rake task_bridge:outbox:publish
```
