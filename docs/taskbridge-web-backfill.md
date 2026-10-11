# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication for an existing TaskBridge
installation, seed the local outbox with the current synchronized state:

```sh
bundle exec rake task_bridge:backfill_sync_provenance DRY_RUN=true
bundle exec rake task_bridge:backfill_sync_provenance
```

The dry run makes no database or external-source changes. It prints JSON counts
for item snapshots by service plus mapping memberships by confidence, including
incomplete records and low-confidence memberships withheld from publication.

The write run only changes TaskBridge's local provenance and outbox tables. It
adds one baseline `item` snapshot per source item, marked with
`provenance.detected_by: backfill` and `backfilled_at`; it does not create
historical observation or sync-run rows. Rerunning it is safe because the same
baseline timestamps produce the same outbox idempotency keys.

Mappings with `high` provenance are published as `confirmed`; `medium`
provenance is published as `inferred`. `low` / title-derived or manual
backfill mappings are retained locally and reported by the dry-run summary, but
are deliberately not enqueued until they are reviewed. Review these counts
before turning on the publisher:

```sh
bundle exec rake task_bridge:outbox:publish_dry_run
bundle exec rake task_bridge:outbox:publish
```

The backfill never contacts provider APIs and does not mutate any external
source system.
