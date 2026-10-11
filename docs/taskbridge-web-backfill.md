# TaskBridge Web baseline backfill

Run the backfill after deploying the provenance and outbox migrations, and before
enabling TaskBridge Web publication. It only reads local TaskBridge data and
writes local provenance/outbox records; it never calls a source provider.

Preview the rows and skips first:

```sh
bundle exec rake task_bridge:outbox:backfill DRY_RUN=1
```

The JSON summary groups item and mapping counts by service, records mapping
confidence counts, and identifies incomplete and low-confidence skips. Review
the latter before publishing. Low-confidence (`low` / `tentative`) memberships
are intentionally withheld; `high` publishes as `confirmed` and `medium` as
`inferred`.

Then seed the local outbox:

```sh
bundle exec rake task_bridge:outbox:backfill
```

The task is safe to rerun. It uses each record's first observation (or existing
local timestamp) to make deterministic keys, and reports already queued rows as
`existing`. Each item row is a current-state baseline snapshot with
`provenance.detected_by: backfill` and `provenance.backfilled_at`; it does not
emit `snapshot_seen` or other historical observation events. It also emits no
backfilled `sync_run` rows because historical run boundaries are unavailable.

Once the preview and outbox counts are accepted, enable normal publication and
use `bundle exec rake task_bridge:outbox:publish` to deliver the queued rows.
