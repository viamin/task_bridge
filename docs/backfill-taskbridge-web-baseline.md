# Backfilling the TaskBridge Web baseline (#222)

How to seed the outbox with baseline rows for existing TaskBridge data
before enabling publication to TaskBridge Web
(RDR #215, "Migration and Backfill Implications"). TaskBridge is a Rails
app; run these from the repository root.

## What the backfill writes

- One `item` current-state snapshot per existing `sync_items` row, marked
  as a baseline observation — not a historical change event — via
  `provenance.detected_by: "backfill"` and `provenance.backfilled_at` in
  the payload. No `snapshot_seen` observation rows are written; the live
  pipeline (#219) emits the first observation on its next refresh.
- `mapping` rows for existing `sync_collection` memberships whose
  confidence translates to `confirmed` (`high`) or `inferred` (`medium`).
  Low-confidence (`tentative`) memberships are withheld from publication —
  the resolved RDR #215 open question — and appear only in the dry-run and
  run summaries so they can be cleaned up manually or reviewed later.
- No `sync_run` rows: `sync_service_states` keeps no reliable per-run
  start/end timestamps, which RDR #215 requires for backfilled summaries.
  Live sync runs publish them going forward.

Single-instance services (OmniFocus, Reminders, Google Tasks, …) publish
under the `service_instance` token `<service_type>:default`
(e.g. `omnifocus:default`); configured instances keep their suffix (e.g.
`asana:work`). The token is embedded in idempotency keys, so it is
permanent once published; the live pipeline uses the same default so
backfilled and live rows share identities.

The backfill reads and writes local data only. It never contacts or
mutates external source systems.

## Running it

```bash
# 1. Preview. Writes nothing. Summarizes counts by service, mapping
#    confidence, and skipped/incomplete records.
bundle exec rake task_bridge:outbox:backfill_dry_run

# 2. Backfill. Idempotent: every row key is derived from data that does
#    not change between runs, so reruns re-find stored rows instead of
#    duplicating them. Also runs the #217 provenance backfill first
#    (service instance names, mapping evidence) when fields are missing.
bundle exec rake task_bridge:outbox:backfill

# 3. Preview the exact batches a publication would send (NDJSON on stdout).
bundle exec rake task_bridge:outbox:publish_dry_run

# 4. Only then enable publication (task_bridge.web.enabled plus base_url
#    and api_key in config/settings.yml) and publish.
bundle exec rake task_bridge:outbox:publish
```

The dry-run summary counts reflect the data currently stored on disk. If
legacy rows are still missing mapping provenance (no `mapping_method`),
a dry run classifies their memberships as withheld (`tentative`), while
the real run backfills provenance first and may publish them as
`confirmed` or `inferred`; rerun the dry run after step 2 for stable
counts.

## Reading the summary

```json
{
  "dry_run": false,
  "items": {
    "enqueued_by_service": {"omnifocus": 312, "asana": 41},
    "skipped_by_reason": {"missing_external_id": 2, "untyped_item": 1}
  },
  "mappings": {
    "collections": 57,
    "enqueued_by_confidence": {"confirmed": 61, "inferred": 9},
    "withheld_by_confidence": {"tentative": 12}
  }
}
```

- `skipped_by_reason` lists records that cannot be identified
  (`missing_external_id`) or predate STI typing (`untyped_item`); fix or
  delete those rows manually — the backfill will never publish them.
- `withheld_by_confidence` lists memberships held back for review. These
  stay identifiable here and via
  `SyncCollection.where(mapping_confidence: "low")` until they are
  re-established by a sync (which upgrades the evidence) or cleaned up
  manually.

## Notes

- Backfilled rows sit in the outbox as `pending` rows like any live row
  and are pruned by the same retention windows once delivered.
- Baseline item snapshots do not advance the live pipeline's diff
  baseline (`last_snapshot`), so the next sync still observes each item
  normally.
