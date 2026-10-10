# TaskBridge Web Baseline Backfill

- Issue: #222
- Parent: #214
- Depends on: #216, #217, #218 (source provenance and mapping metadata
  backfills), #215 (publication contract), #219-#221 (live outbox pipeline)
- Contract: `docs/rdr-215-taskbridge-observation-publication-contract.md`

Existing `sync_items` and `sync_collections` represent real synchronized
work. The baseline backfill seeds the local outbox so TaskBridge Web can
start from the known current state and only treat later diffs as change
history. It is a one-time-per-deployment migration step to run **before**
enabling publication to TaskBridge Web (`task_bridge.web.enabled`).

## What it emits

`Outbox::Backfill` (`rake task_bridge:outbox:backfill_baseline`) writes
local outbox rows only — it never contacts external source systems, and
publication stays gated behind the existing web publisher configuration:

- **Item snapshots** (`record_kind: item`): one current-state snapshot per
  existing `sync_items` row with an `external_id`, built from the
  normalized snapshot (`Base::SnapshotSerializer`). The payload renames
  the snapshot's `metadata` to the contract's `source_metadata` and marks
  the row as baseline via `provenance.detected_by: "backfill"` plus a
  `backfilled_at` timestamp (extra fields are safe: v1 consumers must
  ignore unknown fields).
- **Mapping rows** (`record_kind: mapping`): one
  `representation_membership` row per `SyncCollection` membership, using
  the collection's backfilled mapping provenance.

It deliberately does **not** emit:

- `observation` rows — a baseline snapshot is current state, not a
  historical change event. Live sync runs (#219) publish the first genuine
  `snapshot_seen` observation on each item's next refresh.
- `sync_run` rows — `sync_service_states` has no reliable per-run
  start/end timestamps, which RDR #215 requires for backfilled summaries.
  Normal sync runs publish them going forward.
- Deletion tombstones — the backfill cannot state deletions confidently.

## Confidence policy (resolved decision)

Backfill confidence translation resolves RDR #215's open question in favor
of the RDR's stated default, and preserves the issue #222 decision point
about title-derived mappings explicitly rather than assuming acceptance:

| `SyncCollection#mapping_method` | `mapping_confidence` | Contract `mapping_confidence` | Published? |
|---|---|---|---|
| `source_sync_id` / `created_by_sync` | `high`  | `confirmed` | yes |
| `title_fallback` (title-derived)    | `medium`| `inferred`  | yes |
| `manual_backfill` (no evidence)     | `low`   | — | **withheld** |

Title-derived mappings are published as `inferred` (per the clarified
requirement on #222) so TaskBridge Web can surface them for review; the
product owner has not yet decided how they should be treated long-term,
and upgrading their provenance (for example by the next sync matching
sync IDs) republishes them as `confirmed` with a new idempotency key.

Withheld low-confidence memberships never reach TaskBridge Web; they stay
identifiable through the dry-run summary counts by confidence for manual
cleanup or Web-side review. Item snapshots for members of low-confidence
collections omit their `sync_collection` block so the withheld mapping
fact is not smuggled through the snapshot.

## Idempotency

The backfill can be run multiple times safely:

- Every row's idempotency key derives from stable per-record timestamps —
  `sync_items.last_observed_at` for items and
  `sync_collections.mapping_last_observed_at` (falling back to
  `updated_at`/`created_at`) for mappings — so a rerun re-derives the same
  keys and `OutboxEntry.enqueue` returns the stored rows untouched.
- The identity/provenance backfill (#216-#218) runs first and is itself
  idempotent; it only fills rows whose provenance is missing.
- Source identity uses the permanent default instance token
  (`omnifocus:default`, see `Outbox::SourceIdentity::DEFAULT_INSTANCE`),
  the same one the live pipeline resolves, so backfilled and live rows
  share identities and never collide or duplicate.

If a live sync runs between two backfill runs, changed records produce new
facts with new keys — superseding snapshots, not duplicates.

## Running the backfill

1. Preview the counts first (writes nothing, including no provenance
   backfill):

   ```bash
   bundle exec rake task_bridge:outbox:backfill_baseline_dry_run
   ```

   The summary reports counts by service, by mapping confidence, and
   skipped/incomplete records (for example items without an `external_id`,
   or memberships whose collection has no mapping confidence yet).

2. Run the backfill for real:

   ```bash
   bundle exec rake task_bridge:outbox:backfill_baseline
   ```

3. Optionally preview the exact batches that would be published (the
   rows are now pending in the outbox):

   ```bash
   bundle exec rake task_bridge:outbox:publish_dry_run
   ```

4. Enable publication (`task_bridge.web.enabled` plus `base_url`/`api_key`
   in `config/settings.yml` or their `TASK_BRIDGE_WEB_*` environment
   variables) and publish the baseline:

   ```bash
   bundle exec rake task_bridge:outbox:publish
   ```

   Rerunning the backfill after publication is still safe: already
   delivered rows are deduplicated by idempotency key, and TaskBridge Web
   replays them as `replayed` results.
