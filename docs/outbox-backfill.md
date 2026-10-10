# Outbox Backfill: Baseline State for TaskBridge Web

- Issue: #222
- Parent: #214
- Contract: [RDR 215](rdr-215-taskbridge-observation-publication-contract.md)

Existing `sync_items` and `sync_collections` represent real synchronized
work. The backfill publishes that existing data into the local outbox as
**baseline current state** so TaskBridge Web can start from a known state and
treat only later diffs as change history. Baseline rows are marked as
backfill facts (`provenance.detected_by: "backfill"` plus a `backfilled_at`
timestamp), never as historical change events.

## What the backfill writes

- **Identity/provenance fields** — first runs
  `SyncBackfill::SourceProvenance` (`task_bridge:backfill_sync_provenance`),
  which fills missing source identity (`source_service_name`,
  `source_service_instance`, `source_external_id`, `source_url`,
  `source_updated_at`, observation timestamps) from STI type, `external_id`,
  `url`, `last_modified`, parsed notes, and service instance names, and
  derives mapping metadata for `SyncCollection` rows that have none. Both
  steps are idempotent and local-only.
- **One `item` snapshot row per existing `sync_items` row** — the item's
  normalized snapshot (the same published shape the live observation
  pipeline stores), marked as baseline via payload provenance. Items
  without an external id are skipped and reported as incomplete.
- **`mapping` rows for existing `SyncCollection` memberships** — but only
  memberships whose confidence publishes as `confirmed` (internal `high`,
  sync-id derived) or `inferred` (internal `medium`, title derived).
  Low-confidence/tentative memberships are withheld from publication and
  listed in the dry-run summary counts by confidence instead, for manual
  cleanup or Web-side review.
- **No `sync_run` rows** — `sync_service_states` has no reliable per-run
  start/end timestamps, so backfilled sync-run summaries would be
  fabrications. Normal sync runs publish them going forward (#219-#221).

Withholding low-confidence memberships is a recorded product decision
(RDR 215's open question, resolved with #222); title-derived `medium`
mappings publish as `inferred`. If the product owner later decides to
publish tentative mappings too, the change is localized to
`Outbox::Backfill::PUBLISHABLE_CONFIDENCE`.

## Running the backfill

Run the backfill **before** enabling publication to TaskBridge Web
(`task_bridge.web.enabled`), so TaskBridge Web's first contact receives the
known baseline:

```bash
# 1. Preview: counts by service and mapping confidence; writes nothing.
bundle exec rake task_bridge:outbox:backfill_dry_run

# 2. Backfill: writes baseline rows into the local outbox (idempotent,
#    never contacts TaskBridge Web or any external source system).
bundle exec rake task_bridge:outbox:backfill

# 3. Enable publication (task_bridge.web.enabled plus base_url/api_key in
#    config/settings.yml), then publish the pending baseline rows:
bundle exec rake task_bridge:outbox:publish
```

Example dry-run output:

```
Outbox backfill dry run (nothing was written):
  item snapshots: 812 enqueued, 3 skipped/incomplete
    asana: 190 enqueued, 0 skipped/incomplete
    github: 54 enqueued, 3 skipped/incomplete
    google_tasks: 22 enqueued, 0 skipped/incomplete
    omnifocus: 546 enqueued, 0 skipped/incomplete
  mapping memberships: 402 enqueued, 37 withheld
    high: 351 enqueued, 0 withheld
    low: 0 enqueued, 37 withheld
    medium: 51 enqueued, 0 withheld
```

## Idempotency and safety

- Rerunning the backfill is safe: row identity is deterministic because
  `observed_at` comes from timestamps already stored on the rows
  (`last_observed_at` / `mapping_last_observed_at`, falling back to
  `updated_at`/`created_at`), never from the run clock, so idempotency
  keys — and therefore rows — repeat across runs.
- Stored outbox payloads are immutable across reruns; only delivery state
  changes after insert.
- The backfill never mutates external source systems. It reads local
  `sync_items`/`sync_collections` and writes only the local database (the
  outbox plus the identity/provenance fields above).
- `--pretend` semantics apply as everywhere else: no outbox rows are
  written during pretend runs.

## Live pipeline identity compatibility

Backfilled and live rows share identities: single-instance services
(OmniFocus, Reminders, GitHub as configured by default, Google Tasks) use
the fixed `:default` instance token (for example `omnifocus:default`) in
`Outbox::SourceIdentity`, so baseline and later live observations for the
same item collide on the same source identity. That token is permanent —
it is embedded in idempotency keys — and the live pipeline (#219-#221)
resolves missing instance names the same way.
