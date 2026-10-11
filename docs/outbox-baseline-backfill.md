# Outbox baseline backfill

Run the baseline backfill after deploying the outbox migrations and before enabling TaskBridge Web publication. It only reads local TaskBridge records and writes local provenance and outbox rows; it never contacts a source provider.

Preview first:

```sh
bundle exec rake task_bridge:outbox:backfill DRY_RUN=1
```

The JSON summary groups eligible item snapshots by service, mapping memberships by publication confidence, and incomplete/skipped records. Low-confidence (`tentative`) mappings are listed under `withheld_by_confidence` and are not published. `high` becomes `confirmed`; title-derived `medium` becomes `inferred`.

Then seed the local outbox:

```sh
bundle exec rake task_bridge:outbox:backfill
bundle exec rake task_bridge:outbox:publish_dry_run
```

Review the second command's batches before enabling normal publication. The backfill creates one baseline `item` snapshot per source item and mapping rows only for confirmed or inferred memberships. It creates no observation, deletion, or sync-run rows. Snapshot provenance includes `detected_by: backfill`, `baseline: true`, and `backfilled_at`, so Web treats the data as current state rather than historical change events.

Rerunning the task is safe: stable observation timestamps and deterministic idempotency keys reuse existing rows without changing their payloads.
