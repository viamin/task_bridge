# Backfilling the TaskBridge Web baseline (#222)

Before enabling publication to TaskBridge Web (RDR #215, issue #221),
existing local data must be seeded into the outbox so TaskBridge Web can
start from a known current state and only treat later diffs as change
history.

The backfill writes only local tables (`outbox_entries`). It never
contacts an external source system and never mutates `sync_items` or
`sync_collections` rows.

## What the backfill publishes

- **One `item` snapshot per existing `sync_items` row** — the item's
  normalized snapshot rendered like a live publication, plus
  `provenance.detected_by: "backfill"` and `backfilled_at`. Baseline
  rows are initial observations of *current state*, not historical
  change events, so no `snapshot_seen` observation rows are written
  (clarified decision for #222; TaskBridge Web seeds current state from
  the item rows).
- **One `mapping` row per `SyncCollection` membership** — the same
  contract shape sync runs emit, with the backfill provenance markers
  above.

Idempotency keys embed a deterministic `observed_at` (the item's
`last_observed_at`, or the collection's `mapping_last_observed_at`), so:

- rerunning the backfill never duplicates rows or resets delivery state;
- a rerun can never resubmit the same idempotency key with a different
  payload, even after delivered rows are pruned (`backfilled_at` equals
  the deterministic `observed_at` for the same reason).

If an item changed since the last backfill run, the next run publishes a
*new* baseline snapshot under a new key — that is a new fact about
current state, not a duplicate.

## Low-confidence mapping policy

Resolved per the clarified decision on RDR #215's open question
(backfill scope, #222):

- `high` confidence publishes as `confirmed`
- `medium` confidence publishes as `inferred`
- `low` confidence memberships are **withheld** from publication

Withheld memberships stay identifiable through the dry-run summary
(`withheld (low confidence)` and counts by confidence). They publish
later, at their upgraded confidence, once sync observes stronger
evidence (for example a sync-id match upgrading a title match). Item
snapshots of withheld members omit their `sync_collection` block so a
withheld mapping never leaks through another row kind.

## How to run it

```bash
# 1. Backfill source identity and mapping provenance first (#217/#218):
#    populates source_service_* fields, mapping_method/confidence, and
#    the mapping timestamps the baseline keys are derived from.
bin/rails task_bridge:backfill_sync_provenance

# 2. Preview what would be enqueued (writes nothing):
bin/rails task_bridge:backfill_outbox_baseline_dry_run

# 3. Seed the baseline rows (idempotent — rerunning is safe):
bin/rails task_bridge:backfill_outbox_baseline
```

`task_bridge:backfill_outbox_baseline` runs the provenance backfill
automatically before seeding, so ordering cannot be skipped. The dry-run
task never writes; if it reports skipped "incomplete records" for
mappings, the provenance backfill (step 1) has not classified those
collections yet.

The dry-run summary prints counts by service, by mapping confidence,
and skipped/incomplete records, for example:

```
Outbox baseline backfill (dry run):
  Items: 15 snapshots planned (0 created, 0 already present), 2 skipped (incomplete records)
  Item snapshots by service: asana=6, github=4, google_tasks=3, omnifocus=2
  Mappings: 6 memberships planned (0 created, 0 already present), 3 withheld (low confidence), 1 skipped (incomplete records)
  Mappings by confidence: confirmed=4, inferred=2
  Mappings by service: asana=3, github=2, omnifocus=1
```

## After the backfill

Publication stays disabled until the deployment opts in
(`task_bridge.web.enabled` in `config/settings.yml`, plus `base_url` and
`api_key`):

```bash
# Render the exact batches that would be sent (nothing leaves the machine):
bin/rails task_bridge:outbox:publish_dry_run

# Then enable publication in settings and publish:
bin/rails task_bridge:outbox:publish
```

Normal sync runs become producers going forward: they publish
`source_changed`/`snapshot_seen` observations, mapping rows, and
sync-run summaries. The backfill deliberately writes no `sync_run` rows
because `sync_service_states` keeps no reliable per-run start/end
timestamps (RDR #215 requires them for backfilled sync-run summaries).

## Single-instance service identity

Items from services configured without an instance suffix (OmniFocus,
Reminders, …) publish under the permanent default instance token, e.g.
`omnifocus:default` (`Outbox::SourceIdentity::DEFAULT_INSTANCE`). The
token is embedded in idempotency keys, so it can never change; the live
pipeline resolves the same default so backfilled and live rows share
identities.
