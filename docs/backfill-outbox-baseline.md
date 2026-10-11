# Backfilling the Outbox Baseline for TaskBridge Web

Covers issue #222 under #214. Read alongside
[docs/rdr-215-taskbridge-observation-publication-contract.md](rdr-215-taskbridge-observation-publication-contract.md)
("Migration and Backfill Implications").

## What the backfill does

`Outbox::BaselineBackfill` seeds the local outbox from existing `sync_items`
and `sync_collections` so TaskBridge Web starts from known current state and
only later diffs become change history:

- **Item rows** — one `item` current-state snapshot per existing sync item
  (the normalized snapshot from `Base::SnapshotSerializer`, timestamps as
  ISO 8601 UTC). No `snapshot_seen` observation rows are emitted: a baseline
  is a marked current-state fact, not a historical change event. Each
  payload carries `provenance.detected_by: "backfill"` and a
  `provenance.backfilled_at` timestamp, plus the row-level `observed_at`
  derived deterministically from the item's `first_observed_at` (falling
  back to `created_at`/`updated_at` for legacy rows).
- **Mapping rows** — one `mapping` row per existing `SyncCollection`
  membership, reusing `Outbox::MappingEmitter` with the collection's
  `mapping_established_at` as `observed_at`. Internal confidence vocabulary
  is translated to the contract enum: `high` → `confirmed`, `medium` →
  `inferred`, `low` → `tentative`.
- **Low-confidence mappings are withheld.** Memberships held at `low` (or
  with no confidence recorded yet) are *not* enqueued, per the RDR #215
  open-question resolution recorded in #222: publication is limited to
  `confirmed` and `inferred` mappings. They stay identifiable for manual
  cleanup or Web-side review through the dry-run summary's counts by
  confidence. When a later sync upgrades a collection's mapping provenance,
  the live pipeline (#219) publishes the upgraded mapping on its own.
- **No `sync_run` rows** are backfilled: `sync_service_states` holds only
  the latest attempt per service with no reliable per-run start/end
  timestamps, and RDR #215 requires reliable timestamps for backfilled
  sync-run summaries. Normal sync runs publish them going forward.
- **No tombstones** are invented: deletion is only stated where it can be
  observed confidently (#220).

The backfill only reads `sync_items`/`sync_collections` and writes
`outbox_entries`. It never mutates the synced rows or contacts external
source systems.

## Idempotency

Safe to run any number of times:

- Item rows key on `first_observed_at` (immutable per item), so reruns —
  even after later observations moved the item — resolve to the same
  idempotency key and no new row is written.
- Mapping rows key on `mapping_established_at` (immutable per
  collection).
- `OutboxEntry.enqueue` never overwrites a stored row's payload, so the
  original `backfilled_at` stamp survives reruns.

One caveat: if `task_bridge:backfill_sync_provenance` (#218) runs *after*
this backfill on rows it had never observed, those rows gain
`first_observed_at` values for the first time and the next baseline rerun
will treat them as new baselines. Run the provenance backfill first (see
below) and this never happens.

## How to run it

Run the provenance backfill (#218) first so items carry captured
`source_*` identity and collections carry mapping metadata; it is
idempotent, so rerunning it is harmless:

```bash
bundle exec rake task_bridge:backfill_sync_provenance
```

Preview what the baseline backfill would enqueue (writes nothing):

```bash
bundle exec rake task_bridge:outbox:backfill_baseline_dry_run
```

The dry-run output summarizes counts by service, by mapping confidence,
and skipped/incomplete records — for example:

```
Baseline backfill (dry run: true)
Items: 412 candidates — 412 enqueued, 0 already present, 0 skipped (incomplete), 0 write failures
  omnifocus: 180 enqueued, 0 already present, 0 withheld, 0 skipped (incomplete)
  asana: 96 enqueued, 0 already present, 0 withheld, 0 skipped (incomplete)
  github: 60 enqueued, 0 already present, 0 withheld, 0 skipped (incomplete)
  google_tasks: 76 enqueued, 0 already present, 0 withheld, 0 skipped (incomplete)
Mappings: 214 memberships across 107 collections — 205 enqueued, 0 already present, 9 withheld (low/unknown confidence), 0 skipped (incomplete), 0 write failures
  high: 198 enqueued, 0 already present, 0 withheld, 0 skipped (incomplete)
  medium: 7 enqueued, 0 already present, 0 withheld, 0 skipped (incomplete)
  low: 0 enqueued, 0 already present, 9 withheld, 0 skipped (incomplete)
```

Records reported as *skipped (incomplete)* lack an `external_id` (items)
or a member `external_id` (memberships); they publish once their source
refresh captures one.

Seed the baseline (safe to rerun):

```bash
bundle exec rake task_bridge:outbox:backfill_baseline
```

Then enable publication to TaskBridge Web (#221):

```bash
bundle exec rake task_bridge:outbox:publish          # once enabled in settings
bundle exec rake task_bridge:outbox:publish_dry_run  # NDJSON preview of the batches
```

## Decisions baked into the backfill

These resolved #222's clarifying questions and RDR #215's open question;
they are recorded in the RDR's "Follow-up Decisions" section:

1. **Withhold low-confidence mappings** from backfill publication; only
   `confirmed` and `inferred` rows are enqueued, with low-confidence
   memberships visible in the dry-run summary. Whether TaskBridge Web
   should ever receive `tentative` mappings remains a separate product
   decision — this backfill does not assume an answer beyond the RDR's
   safer default.
2. **Item rows only** for existing items: no `snapshot_seen` observation
   rows from the backfill, so TaskBridge Web seeds current state from
   item snapshots and history starts with the next live observation.
3. **Permanent default service instance token**: single-instance services
   publish as `<service_type>:default` (e.g. `omnifocus:default`) via
   `Outbox::SourceIdentity`. The token is embedded in idempotency keys
   and can never change; the live pipeline (#219-#221) resolves
   identities through the same module so backfilled and live rows share
   identities.
4. **No backfilled sync-run summaries** (see above).
