# TaskBridge Web baseline backfill

Run the baseline backfill after deploying the outbox migrations and before
enabling `task_bridge.web.enabled`. It writes local provenance and baseline
`item` snapshots only; it never calls a source provider, sends HTTP requests,
or creates historical observation or sync-run events.

Preview the work first:

```sh
DRY_RUN=1 bundle exec rake task_bridge:backfill_observations
```

The command emits a JSON summary with item counts by service and mapping
counts by confidence, including incomplete records and low-confidence
memberships withheld from publication. A dry run makes no database writes.

Apply the backfill, which is safe to rerun because outbox rows have stable
idempotency keys:

```sh
bundle exec rake task_bridge:backfill_observations
```

Each item snapshot is tagged with `provenance.detected_by: backfill` and its
stable `backfilled_at` timestamp. It also seeds the local snapshot baseline,
so future syncs publish only real changes. High-confidence mappings are
published as `confirmed`, medium-confidence mappings as `inferred`, and
low-confidence/title-derived mappings are deliberately withheld. Review their
count in the dry-run output before resolving them locally or in a later Web
workflow.

Once the summary is acceptable, enable publication and use the normal outbox
publisher:

```sh
bundle exec rake task_bridge:outbox:publish
```
