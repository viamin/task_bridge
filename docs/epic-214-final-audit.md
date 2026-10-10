# Epic #214 Final Audit: Observation and Publication Layer

- Status: Complete — audited against RDR #215 (`docs/rdr-215-taskbridge-observation-publication-contract.md`)
- Date: 2026-10-10
- Issue: #214

## Audit method

Every issue-tree area under the epic was verified against the shipped code,
its tests, and its documentation on this branch. Closed child issues were not
treated as sufficient evidence: each area below names the implementing files,
the covering specs, and the documenting file, all re-checked directly. One
required gap was found and corrected as part of this audit (see "Corrections
applied").

## Area-by-area verification

| Area | Implementation | Tests | Docs | Result |
|---|---|---|---|---|
| RDR / contract decision (#215) | `docs/rdr-215-…-contract.md` (Accepted, with follow-up decisions folded in) | consumer contract specs below | same | Verified |
| Identity / provenance (#216) | `20260817094249_add_source_provenance_to_sync_items_and_collections.rb`, `Outbox::SourceIdentity`, `SyncMappingProvenance`, `SyncBackfill::SourceProvenance` + `task_bridge:backfill_sync_provenance` | `spec/models/base/sync_item_spec.rb`, `spec/tasks/backfill_sync_provenance_task_spec.rb` | `docs/normalized-snapshot-field-support.md` (source identity format) | Verified |
| Source snapshots (#217, #223) | `Base::SnapshotSerializer` + per-adapter `normalized_metadata` (all 8 task adapters + Google Calendar facts) | `spec/services/base/snapshot_serializer_spec.rb`, per-adapter model specs | `docs/normalized-snapshot-field-support.md`, `docs/source-capability-matrix.md` | Verified |
| Observation outbox (#218) | `OutboxEntry` (+ migration, unique idempotency index, `attr_readonly` canonical payload) | `spec/models/outbox_entry_spec.rb`, `spec/models/outbox_entry_indexes_spec.rb` | RDR #215 migration notes | Verified |
| Change detection (#219) | `Outbox::ObservationEmitter`, `Outbox::SnapshotDiff`, `sync_items.last_snapshot` baseline, hooked into `Base::SyncItem#refresh_from_external!` | `spec/services/outbox/observation_emitter_spec.rb`, `spec/services/outbox/snapshot_diff_spec.rb` | `docs/normalized-snapshot-field-support.md` (emission section) | Verified |
| Mappings | `Outbox::MappingEmitter`, hooked into `persist_sync_collection_for` / provenance changes, confidence vocabulary mapped to the contract | `spec/services/outbox/mapping_emitter_spec.rb` | `docs/normalized-snapshot-field-support.md` | Verified |
| Deletions / disappearance (#220) | `Disappearance::{Detector,Finding,States,Strategy}` + per-adapter strategies (Keep, Reminders, OmniFocus, Asana; others explicitly disabled) | `spec/services/disappearance/detector_spec.rb`, per-adapter `deletion_detection_spec.rb` | `docs/source-deletion-detection.md` | Verified |
| Publisher (#221) | `Outbox::WebPublisher` (+ `Batch`, `Client`, `Config`, `Reconciler`, `Response`), end-of-run publication in `task_bridge:sync`, `task_bridge:outbox:publish`, prune task, backoff config | `spec/services/outbox/web_publisher_spec.rb` + per-class specs, `spec/tasks/outbox_publish_task_spec.rb`, `spec/tasks/outbox_prune_task_spec.rb`, `spec/models/outbox_entry_spec.rb` (retry state) | RDR #215; README (added by this audit) | Verified |
| Sync-run summaries | `Outbox::SyncRunEmitter` (added by this audit), wired into `task_bridge:sync` after `SyncServiceState.record_summary!` | `spec/services/outbox/sync_run_emitter_spec.rb`, `spec/tasks/sync_task_spec.rb` | RDR #215 schema; `docs/normalized-snapshot-field-support.md` | Corrected during audit |
| Source metadata gaps (#223) | per-adapter `normalized_metadata` (section names/ids, repo, number, lists, priority, reading progress, …) | per-adapter model specs | `docs/source-capability-matrix.md`, `docs/normalized-snapshot-field-support.md` | Verified |
| GitHub activity (#224) | `Github::ActivityEmitter` (timeline + review facts, per-event idempotency, cursor via `SyncServiceState.record_activity_sync!`) | `spec/services/github/activity_emitter_spec.rb`, `spec/tasks/sync_task_spec.rb` (cursor advance/retain) | `docs/source-capability-matrix.md` | Verified |
| Calendar context | `GoogleCalendar::Service` (read-only, busy/free default, bounded window, `privacy_mode` gate for details) | `spec/services/google_calendar/service_spec.rb` | RDR #215 privacy constraints; `config/settings.yml` | Verified |
| Backfills | identity/mapping backfill (`SyncBackfill::SourceProvenance`); observation baselines seed organically — the first refresh of each item emits `snapshot_seen` with the full snapshot embedded; `task_bridge:outbox:publish_dry_run` renders backfill batches without sending | `spec/tasks/backfill_sync_provenance_task_spec.rb`, `observation_emitter_spec.rb` (first-observation), `outbox_publish_task_spec.rb` (dry run) | RDR #215 migration notes | Verified (see "Deferred with rationale") |
| Tests / observability / privacy / docs | failure isolation (`Outbox::IsolatedWrite`), `--pretend` never writes, Pact consumer contract + committed pact (`spec/pacts/taskbridge-taskbridge_web.json`), notes never published as text (HMAC `notes_digest` only) | `spec/services/outbox/isolated_write_spec.rb`, `spec/services/outbox/web_publisher/task_bridge_web_contract_spec.rb`, emitters' pretend specs | `docs/pact-consumer-contract-testing.md` | Verified |

## Acceptance criteria

1. **Dependency-ordered implementation issues under the epic** — tracked on
   GitHub; code comments and docs reference the issue numbers (#215–#225,
   #250) in dependency order (e.g. #217 depends on #215/#216).
2. **First implementation issue depends on the approved RDR** — #216+ cite
   RDR #215; `docs/normalized-snapshot-field-support.md` records the
   dependency edges explicitly.
3. **Existing sync behavior remains compatible** — publication is disabled
   by default (`task_bridge.web.enabled: false`), emission paths are
   write-only bookkeeping wrapped in `Outbox::IsolatedWrite`, `--pretend`
   never writes, and the publisher runs after sync and never changes its
   exit status. The full suite (716 examples pre-audit) passes unchanged.
4. **Normalized, idempotent facts publishable without source-specific API
   knowledge** — items/observations/mappings/sync_runs are published under
   the versioned batch contract with deterministic idempotency keys and
   partial-success reconciliation, verified end-to-end by the Pact consumer
   contract against TaskBridge Web.

## Corrections applied by this audit

1. **Sync-run summaries had no producer.** The contract, outbox, idempotency
   keys, and batch support all carried `sync_run` rows, but nothing in the
   sync flow ever enqueued them, so TaskBridge Web could not correlate item
   observations with run health (RDR #215 "Sync-Run Summary Schema" says
   TaskBridge publishes one summary per service run). Added
   `Outbox::SyncRunEmitter`, wired into `task_bridge:sync` alongside
   `SyncServiceState.record_summary!`, with unit and task-level specs.
   Skipped/idle services publish nothing; failed runs carry
   `error.retryable: true`, matching the existing next-scheduled-run retry
   policy.
2. **README did not document the publication layer.** Added a "TaskBridge
   Web publication" section covering the outbox, configuration, rake tasks,
   and privacy defaults.
3. **Docs gap** — sync-run emission is now described in
   `docs/normalized-snapshot-field-support.md` alongside the other emitters.

## Deferred with rationale (not required gaps)

- **`notes_preview` export setting** — intentionally absent: the RDR requires
  an explicit per-source user opt-in before any note text can leave
  TaskBridge; until that setting exists, only the keyed `notes_digest` is
  published. Building the opt-in without a product decision would invert the
  privacy default.
- **Standalone outbox backfill rake task** — not needed for correctness:
  `snapshot_seen` rows embed the full normalized snapshot, so each existing
  item's first refresh after upgrade publishes its baseline observation
  deterministically; `task_bridge:outbox:publish_dry_run` already renders
  batches for file/stdout backfill per the RDR.
- **RDR open question (low-confidence mapping backfill)** — remains open by
  decision; the safer default (publish only `confirmed`/`inferred`) is what
  the implementation ships.
- **`partial` run status** — reserved by the contract; TaskBridge records
  only `success`/`failed` runs today, so the emitter publishes only those.

## Outcome

All issue-tree areas under epic #214 are implemented, tested, and documented
against RDR #215, with the one required gap (sync-run summary production)
corrected during this audit and no remaining required gaps known. The epic's
acceptance criteria are met on this branch.
