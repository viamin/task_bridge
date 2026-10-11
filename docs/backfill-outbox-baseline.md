# Backfilling the Outbox Baseline for TaskBridge Web

Before enabling publication to TaskBridge Web (RDR
[#215](rdr-215-taskbridge-observation-publication-contract.md), issue #222),
existing synchronized data — `sync_items` and `sync_collections` that
represent real synchronized work — must be seeded into the local outbox as
**baseline current state**. TaskBridge Web then starts from the known
current state, and only later diffs are treated as change history.

## What the backfill writes

`Outbox::BaselineBackfill` (`rake task_bridge:outbox:backfill_baseline`):

1. **Runs the provenance backfill first** (`SyncBackfill::SourceProvenance`,
   #218) when applying: it stamps `source_*` identity fields,
   `first_observed_at`/`last_observed_at` on items, and mapping
   method/confidence/metadata on collections. It is idempotent on its own
   and is simply rerun.
2. **One `item` snapshot row per existing `sync_items` row**, built from the
   item's normalized snapshot. Baseline rows are marked in the payload —
   `provenance.detected_by: "backfill"` plus a `backfilled_at` timestamp —
   instead of pretending to be historical change events. The backfill
   deliberately writes **no `snapshot_seen` observation rows** and **no
   `sync_run` rows** (`sync_service_states` has no reliable per-run
   start/end timestamps; live sync runs publish those going forward).
3. **One `mapping` row per existing `SyncCollection` membership**, using the
   same payload shape as the live `Outbox::MappingEmitter`.

### Confidence handling (explicit decision point)

Internal mapping confidence translates to the contract enum as
`high → confirmed`, `medium → inferred` (title-derived), and
`low → tentative`.

The product owner has not yet decided how pre-existing low-confidence
mapping data should be treated long-term. Per the RDR #215 default
(confirmed for #222), the backfill **withholds** low-confidence and
never-classified memberships from publication — they are never written to
the outbox. They stay identifiable through the dry-run summary's
`mappings.by_confidence` counts (and directly in the database via
`SyncCollection#mapping_confidence`) for later manual cleanup or Web-side
review once a final policy is chosen. To change the policy, adjust
`Outbox::BaselineBackfill::WITHHELD_CONFIDENCES` and rerun the backfill —
newly publishable rows enqueue; previously withheld facts start flowing
with fresh idempotency keys.

### Default service instance token

Every row requires a stable `service_instance`, embedded in idempotency
keys. Services without a configured instance suffix (OmniFocus, Reminders,
Google Tasks, ...) publish as `<service_type>:default` (for example
`omnifocus:default`), matching `Outbox::SourceIdentity::DEFAULT_INSTANCE`.
This token is **permanent**: changing it would break every published
identity and idempotency key, so the live pipeline (#219-#221) uses the
same default and backfilled and live rows share identities.

## How to run it

From the repository root, preview first, then apply:

```bash
# 1. Preview: counts only, writes nothing (no outbox rows, no provenance)
rake task_bridge:outbox:backfill_baseline DRY_RUN=1

# 2. Apply: writes pending outbox rows (never contacts external services)
rake task_bridge:outbox:backfill_baseline

# 3. Optional: render the exact batches that would be sent, still offline
rake task_bridge:outbox:publish_dry_run
```

The dry-run output summarizes, as JSON on stdout: item counts by service
(`enqueued` / `existing` / `skipped` plus `skipped_reasons` such as
`missing_external_id`), and mapping counts by internal confidence
(`high` / `medium` / `low` / `unknown`) plus withheld and skipped totals.

Only after reviewing that output, enable publication
(`task_bridge.web.enabled` plus `base_url`/`api_key` in
`config/settings.yml` or the `TASK_BRIDGE_WEB_*` environment variables) and
deliver the baseline with the normal publisher:

```bash
rake task_bridge:outbox:publish
```

## Idempotency and safety

- Every row's idempotency key embeds an `observed_at` derived
  deterministically from stored data (the item's `last_observed_at`, or the
  collection's `mapping_last_observed_at`, falling back to record
  timestamps), so **rerunning the backfill returns the stored rows instead
  of duplicating facts**. Run it as many times as needed.
- Rows whose fact genuinely changed between runs (for example the item was
  re-observed) get a new key and enqueue as a new fact — TaskBridge Web
  keeps the latest `observed_at` as current state, and replays of pruned
  rows are deduplicated server-side by idempotency key.
- The backfill reads and writes **local tables only** (`sync_items`,
  `sync_collections`, `outbox_entries`); it never calls provider APIs, so
  external source systems are never mutated.
