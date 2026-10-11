# Baseline Outbox Backfill (#222)

Parent epic: #214. Contract: [RDR 215](rdr-215-taskbridge-observation-publication-contract.md).
Depends on the provenance backfill (#216-#218, `task_bridge:backfill_sync_provenance`)
and the outbox/live emitters (#219-#221).

## What it does

`SyncBackfill::Baseline` turns existing local TaskBridge data — `sync_items`,
`sync_collections` — into the baseline the observation pipeline publishes to
TaskBridge Web, so TaskBridge Web starts from known current state and only
later rows read as change history:

1. **Provenance refresh**: runs `SyncBackfill::SourceProvenance` (the
   `task_bridge:backfill_sync_provenance` task) so every item carries
   `source_service_name`/instance/type/external id/URL/updated-at and
   first/last-observed timestamps, and every collection carries mapping
   method/confidence/metadata. Idempotent; skipped entirely by dry runs.
2. **Baseline item snapshots**: one `record_kind: "item"` outbox row per
   existing `sync_items` row, built from the shared `normalized_snapshot`
   (so baseline and live rows always agree on field shape).
3. **Baseline mapping rows**: one `record_kind: "mapping"` row per existing
   `SyncCollection` membership, reusing `Outbox::MappingEmitter`.

The backfill only writes local rows. It never contacts providers or
TaskBridge Web, never mutates external source systems, and `--pretend`
runs are irrelevant to it (it is a rake task, not the sync flow).

## Clarified decisions baked into the implementation

| Decision | Choice (clarified on #222) |
| --- | --- |
| Baseline item rows | One `item` snapshot per item, marked `provenance.detected_by: "backfill"` with a `backfilled_at` timestamp. **No `snapshot_seen` observation rows** — baselines are not historical change events. |
| Low-confidence mappings | **Withheld from publication.** Only `confirmed` (internal `high`) and `inferred` (internal `medium`, i.e. title-derived) memberships are enqueued. `low`/`tentative` memberships appear only in the summary's `withheld` counts by confidence and method, keeping them identifiable for manual cleanup. The live emitter (#219) still publishes live mapping rows at any confidence. |
| `service_instance` default | Services without a configured instance (OmniFocus, Reminders, …) publish `<service_type>:default` (e.g. `omnifocus:default`), matching the RDR 215 example `asana:workspace-12345:default`. This token is embedded in idempotency keys and can never change; the live emitters (#219-#221) use the same default via `Outbox::SourceIdentity` so backfilled and live rows share identities. |
| `sync_run` rows | **None.** `sync_service_states` holds no reliable per-run start/end timestamps, and RDR 215 only allows backfilled sync-run summaries where reliable timestamps exist. Normal runs publish them going forward. |

The low-confidence policy remains a recorded decision point (RDR 215 "Open
Questions"): product guidance on #222 resolved it toward the RDR's stated
default for the backfill, but how TaskBridge Web should eventually surface
title-derived (`inferred`) versus unconfirmed (`tentative`) mappings for
review is still open. Revisit before treating `tentative` publication as
settled.

## How to run it

Run the backfill **before** enabling publication to TaskBridge Web
(`task_bridge.web.enabled`), so the first batches TaskBridge Web receives
are the baseline:

```bash
# 1. Preview: writes nothing, prints the full summary
bundle exec rake task_bridge:outbox:backfill_baseline_dry_run

# 2. Backfill: upgrades provenance, enqueues baseline rows
bundle exec rake task_bridge:outbox:backfill_baseline

# 3. Optional: inspect the exact batches that would be sent
bundle exec rake task_bridge:outbox:publish_dry_run

# 4. Enable task_bridge.web.enabled, then publish
bundle exec rake task_bridge:outbox:publish
```

Both backfill tasks are safe to run any number of times, including after
live syncs have already run.

## Dry-run output

```
Baseline backfill (dry run — nothing was written)
  provenance upgraded: 0 sync_items, 0 sync_collections
  item snapshots: considered 412, would enqueue 410
    by service: asana 96, github 41, google_tasks 22, omnifocus 251
    skipped: missing_external_id 2
  mapping memberships: considered 260, would enqueue 194
    by confidence: confirmed 102, inferred 92
    by method: source_sync_id 102, title_fallback 92
    withheld low-confidence: low 66
    skipped: missing_external_id 0
  sync_run summaries: none (no reliable historical timestamps — RDR #215)
```

Dry runs write nothing at all — not even provenance — yet evaluate the same
effective provenance, identities, and idempotency keys a real run would
persist, so the preview matches the subsequent real run row for row
(legacy rows included: identities are inferred in memory from peer sync-id
notes exactly as `SyncBackfill::SourceProvenance` persists them).

`SyncBackfill::Baseline.run!` returns the same data as a hash
(`Summary#to_h`) for scripted use.

## Idempotency and rerun semantics

- Item rows are keyed `tb:v1:item:<service_instance>:<external_id>:snapshot:<observed_at>`,
  with `observed_at` taken from the item's `last_observed_at` (or, for legacy
  rows, `updated_at`/`created_at` — the same value the provenance backfill
  persists). Re-running without data changes produces the same keys.
- Mapping rows are keyed on the collection's `mapping_last_observed_at`
  (same fallback) through `Outbox::MappingEmitter`.
- On top of key determinism, the backfill skips any identity that already
  has a baseline row, so a rerun after items changed does **not** enqueue a
  second baseline: later changes belong to the live observation pipeline.
- A failed or interrupted run can simply be re-run; skipped-and-retried
  rows get identical keys.

## Low-confidence mapping cleanup

Withheld memberships are not published anywhere; they stay visible through
`withheld` counts (by raw confidence and method) in every dry-run summary.
To clean them up, establish real evidence (sync-id notes or a manual link)
and re-run: upgraded collections then enqueue `confirmed`/`inferred`
mapping rows through the normal backfill or live sync paths.
