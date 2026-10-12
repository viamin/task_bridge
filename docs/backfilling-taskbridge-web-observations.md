# Backfilling TaskBridge Web observations

Run the backfill once after deploying the observation/outbox migrations and
before enabling TaskBridge Web publication. It reads only TaskBridge's local
database; it never contacts or mutates an external source system.

First preview the records and review the service, confidence, and incomplete
counts:

```sh
DRY_RUN=1 bundle exec rake task_bridge:backfill_observations
```

Then enqueue the baseline rows:

```sh
bundle exec rake task_bridge:backfill_observations
```

The task fills in legacy source and mapping provenance, creates one `item`
current-state snapshot for every complete local item, and adds mapping rows
for confirmed and inferred memberships. Every snapshot carries
`provenance.detected_by: backfill` and `backfilled_at`; it does **not** create
historical `snapshot_seen`, change, deletion, or sync-run events.

Low-confidence/title-derived mappings are intentionally withheld. Their count
appears in the preview so they can be repaired locally or reviewed before a
later sync establishes stronger evidence. Outbox idempotency keys use the
item's stable first-observed timestamp, so rerunning the task is safe.
