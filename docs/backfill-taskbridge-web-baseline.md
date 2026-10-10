# Backfilling the TaskBridge Web baseline (#222)

Existing `sync_items` and `sync_collections` represent real synchronized
work. Before enabling publication to TaskBridge Web
([RDR 215](rdr-215-taskbridge-observation-publication-contract.md)), run this
backfill so TaskBridge Web starts from the known current state and only later
diffs read as change history.

## What it writes

- Runs the local provenance backfill first (`rake
  task_bridge:backfill_sync_provenance`, #218): source identity fields on
  `sync_items` (STI type, `external_id`, `url`, `last_modified`, parsed sync
  notes, inferred service instance names) and mapping method, confidence, and
  metadata on `sync_collections`.
- One current-state `item` snapshot outbox row per existing `sync_items` row.
  The payload is the normalized snapshot plus
  `provenance.detected_by: "backfill"` and a `backfilled_at` timestamp, so
  TaskBridge Web can tell baseline state apart from later change events.
- `mapping` outbox rows for existing `SyncCollection` memberships.

## What it deliberately does not write

- No `observation` rows: the baseline is not reconstructed history, so the
  backfill never emits `snapshot_seen`, `source_changed`, or `deleted` events.
  Live sync runs (#219-#221) publish those going forward.
- No `sync_run` rows: `sync_service_states` has no reliable per-run
  start/finish timestamps, and RDR 215 only backfills sync-run summaries where
  reliable historical timestamps exist.
- No external writes: the backfill only touches the local database and outbox.
  Source systems are never mutated or even contacted.
- No publication: rows wait in the outbox until
  `task_bridge.web.enabled` is turned on (#221) and
  `rake task_bridge:outbox:publish` runs.

## Low-confidence mappings

Backfill translates local mapping confidence to the contract's vocabulary:

| Local `mapping_confidence` | Contract `mapping_confidence` | Published by backfill? |
|---|---|---|
| `high` (sync-id or created-by-sync evidence) | `confirmed` | yes |
| `medium` (title-derived match) | `inferred` | yes |
| `low` (manual backfill / no evidence) | `tentative` | **no — withheld** |

Withheld memberships never reach TaskBridge Web from the backfill; they stay
identifiable through the dry-run summary (counts by confidence plus a listing
of collection, member, and evidence) until a later sync upgrades their
provenance. How low-confidence mappings should surface in TaskBridge Web is an
open product decision — treat this policy as revisitable rather than settled.

## `service_instance` default

Single-instance services (OmniFocus, Reminders, Google Tasks, …) have no
configured instance suffix, so their published `service_instance` is
`<service_type>:default` (for example `omnifocus:default`), matching RDR 215.
This default is permanent — it is embedded in idempotency keys — and the live
pipeline (#219-#221) resolves the same value through
`Outbox::SourceIdentity`, so backfilled and live rows share identities.

## How to run it

```bash
# 1. Preview: summarize counts by service and confidence, list withheld
#    low-confidence memberships, and list skipped incomplete records.
#    Writes nothing.
bundle exec rake task_bridge:outbox:backfill_baseline_dry_run

# 2. Backfill (idempotent — safe to rerun; existing rows are re-found,
#    not duplicated, because keys are deterministic).
bundle exec rake task_bridge:outbox:backfill_baseline

# 3. Optionally preview the exact batches that would be sent:
bundle exec rake task_bridge:outbox:publish_dry_run

# 4. Enable publication (task_bridge.web.enabled plus base_url/api_key in
#    config/settings.yml or Chamber env vars), then publish:
bundle exec rake task_bridge:outbox:publish
```

Run the backfill (step 2) before enabling publication so TaskBridge Web
receives the baseline first; after that, ordinary sync runs keep the outbox
current. If a backfill row's `observed_at` fact is unchanged, rerunning after
delivered rows were pruned re-derives the same idempotency key but a new
`backfilled_at` value, which TaskBridge Web rejects as a payload conflict —
rerun the backfill only when you mean to (re)seed.
