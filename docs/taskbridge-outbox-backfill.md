# TaskBridge Web outbox backfill

Before enabling `task_bridge.web.enabled`, seed the local outbox from existing
sync data. The backfill only reads local `sync_items` and `sync_collections`;
it never contacts a provider or mutates a source system.

Preview the work first:

```sh
bundle exec rake task_bridge:backfill_outbox DRY_RUN=1
```

The JSON summary groups item candidates by service, mapping candidates by
contract confidence and service, and reports skipped incomplete records.
Tentative (low-confidence) mappings are listed as `withheld`; they are not
placed in the outbox for publication.

When the preview is acceptable, seed the outbox:

```sh
bundle exec rake task_bridge:backfill_outbox
```

The task first fills missing local provenance and mapping metadata, then writes
one baseline `item` snapshot per known source item and confirmed or inferred
membership mappings. Baseline rows carry `provenance.detected_by` of
`backfill`, `baseline: true`, and `backfilled_at`; they are not historical
`snapshot_seen` observations. No `sync_run` rows are created because existing
service state does not provide reliable per-run timing.

It is safe to rerun: deterministic keys return the existing outbox entries and
the baseline snapshot is only stored locally when no prior diff baseline exists.
After checking the pending outbox rows (optionally with
`bundle exec rake task_bridge:outbox:publish_dry_run`), enable publication in
the deployment configuration and run `bundle exec rake task_bridge:outbox:publish`.
