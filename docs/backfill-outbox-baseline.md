# Backfilling Baseline Snapshots, Mappings, and First-Observed Observations

- Issue: #222
- Parent: #214
- Depends on: #216, #217, #218 (normalized snapshots, sync item provenance,
  local observation outbox)
- Contract: RDR #215 (`docs/rdr-215-taskbridge-observation-publication-contract.md`),
  "Migration and Backfill Implications" and "Open Questions"

Existing `sync_items` and `sync_collections` represent real synchronized work
that predates the outbox. This backfill gives TaskBridge Web a safe baseline
current state to seed from, so only facts observed *after* the backfill are
treated as change history.

## What the backfill does

Three separate, idempotent steps, each safe to rerun:

1. **Identity/provenance backfill** (`SyncBackfill::SourceProvenance`,
   already shipped): fills in `source_service_name`, `source_service_instance`,
   `source_service_type`, `source_external_id`, `source_url`,
   `first_observed_at`/`last_observed_at` on `sync_items`, and
   `mapping_method`/`mapping_confidence`/`mapping_metadata` on
   `sync_collections`, inferring both from existing notes-based sync IDs and
   title matches where no explicit data exists.
2. **Baseline item snapshots** (`SyncBackfill::BaselineSnapshots`): enqueues
   one `item`-kind `OutboxEntry` per existing `sync_items` row representing
   its current state. These rows are tagged
   `provenance.detected_by: "backfill"` plus `provenance.backfilled_at`, and
   deliberately **never** pair with a `snapshot_seen` observation row — a
   baseline is not a detected change, so it is published only as current
   state (RDR #215 "Migration and Backfill Implications").
3. **Mapping observations** (`SyncBackfill::MappingObservations`): enqueues
   one `mapping`-kind `OutboxEntry` per eligible `sync_collections` membership
   that already carries `confirmed` (`mapping_confidence: high`) or
   `inferred` (`mapping_confidence: medium`) provenance.

## Low-confidence mappings are withheld, not published

RDR #215 left open whether backfill should publish `sync_collection`
memberships TaskBridge only matched by `manual_backfill` (no sync-ID or title
evidence at all — `mapping_confidence: low`). This is resolved as: **withhold
them**. `SyncBackfill::MappingObservations` enqueues nothing for low-confidence
or collections with fewer than two eligible members; it only counts them
under `skipped["low_confidence_withheld"]` / `skipped["insufficient_members"]`
in its summary. The same withholding applies to the `sync_collection` field
nested inside a baseline item snapshot — it is omitted rather than described
as `tentative` — so a low-confidence grouping never reaches TaskBridge Web
through either record kind. Low-confidence mappings stay identifiable for
manual cleanup only through the dry-run summary (see below) until a sync
later upgrades their provenance, at which point the live pipeline
(`Outbox::MappingEmitter`) publishes them normally.

## The `service_instance` default token

Every item or observation needs `source.service_instance`, and that value is
embedded permanently in idempotency keys (RDR #215 "Idempotency Keys") — it
cannot change later without invalidating every key already published. Services
with no configured instance suffix (OmniFocus, Reminders, a single-workspace
Asana, ...) get a fixed `<service_type>:default` token (e.g.
`omnifocus:default`) instead of a bare service type. This is implemented once,
in `Outbox::SourceIdentity.for`, so backfilled rows and rows the live pipeline
(#219-#221) emits later for the same item always agree on identity.

## Running the backfill

Run these in order, before enabling `task_bridge.web.enabled` or running
`rake task_bridge:outbox:publish` for the first time, so TaskBridge Web's
first ingested facts are the baseline rather than a live diff against nothing:

```bash
# 1. Backfill identity/provenance columns (idempotent, no outbox writes)
bundle exec rake task_bridge:backfill_sync_provenance

# 2. Preview the outbox backfill: counts by service, by confidence, and by
#    skip reason, grouped under "items" and "mappings". Writes nothing.
bundle exec rake task_bridge:outbox:backfill_dry_run

# 3. Run it for real (safe to rerun; reruns find the same rows and change
#    nothing)
bundle exec rake task_bridge:outbox:backfill
```

Step 1 must run first: `SyncBackfill::BaselineSnapshots` and
`SyncBackfill::MappingObservations` read `source_service_instance` and
`mapping_method`/`mapping_confidence` directly off existing rows rather than
re-inferring them, so an unbackfilled item would get published under the
default instance token even if it actually has a configured one.

## What it never does

- It never mutates external source systems — every step only reads
  `sync_items`/`sync_collections` and writes local `OutboxEntry` rows (or, for
  step 1, the provenance columns on those same local tables).
- It never sends anything over HTTP. Publishing is `rake
  task_bridge:outbox:publish`'s job, gated by `task_bridge.web.enabled`
  (`config/settings.yml`), and happens on whatever rows already sit in the
  outbox — backfilled or live.
