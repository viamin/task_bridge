# Epic #214 Final Audit

- Epic: #214 — TaskBridge as the deterministic observation and publication layer
- Decision record: RDR #215 (`docs/rdr-215-taskbridge-observation-publication-contract.md`)
- Date: 2026-10-10

This is the umbrella audit required before the epic closes. It verifies shipped
behavior, tests, and documentation against RDR #215 and the epic's acceptance
criteria — closed child issues alone were not treated as evidence.

## Acceptance criteria verification

| Criterion | Status | Evidence |
|---|---|---|
| Dependency-ordered implementation issues under the epic | Met | Child docs record `Depends on` chains: #217 depends on #215/#216; #223 on #217; #219/#220/#221 build on #218's outbox; #224/#225 on the observation pipeline; #250 pins the wire contract |
| First implementation issue depends on the approved RDR | Met | `docs/normalized-snapshot-field-support.md` declares #217 blocked on #215 (contract) and #216 (identity columns); RDR #215 status is Accepted with folded-in owner decisions |
| Existing sync behavior remains compatible | Met | Publication is opt-in (`task_bridge.web.enabled: false`); all emitters run as post-sync bookkeeping inside `Outbox::IsolatedWrite`; `--pretend` writes no outbox rows; full suite (716 pre-audit examples) passes unchanged |
| TaskBridge can publish normalized, idempotent facts Web can reason over | Met after correction | Observations, mappings, and item snapshots-on-discovery published with deterministic `tb:v1:*` keys; **sync-run summaries had no producer — corrected in this audit** (below) |

## Verified implementation areas

- **Contract (RDR #215)**: `Outbox::IdempotencyKey` implements the `tb:v1`
  record-key format including collision-sequence segments;
  `Outbox::WebPublisher::Batch` sends the versioned batch body and headers to
  `POST /api/task_bridge/v1/ingestion/batches`; the committed Pact
  (`spec/pacts/taskbridge-taskbridge_web.json`, #250) pins the v1 wire shape.
- **Identity/provenance (#216)**: `sync_items.source_*` capture columns,
  `SyncCollection` mapping method/confidence/metadata,
  `SyncMappingProvenance`, and the `task_bridge:backfill_sync_provenance`
  rake (`app/services/sync_backfill/source_provenance.rb`) seed existing rows.
- **Source snapshots (#217)**: `Base::SnapshotSerializer` plus per-adapter
  `normalized_metadata`; support matrix in
  `docs/normalized-snapshot-field-support.md`.
- **Observation outbox (#218)**: `OutboxEntry` with unique idempotency-key
  dedupe, immutable payload/identity (`attr_readonly`), exponential backoff
  with jitter, terminal-failure state, and retention pruning
  (`Outbox::Prune`, `task_bridge:outbox:prune`).
- **Change detection (#219)**: `Outbox::SnapshotDiff` (field allow-list,
  order-insensitive arrays, time normalization) drives
  `Outbox::ObservationEmitter` from `refresh_from_external!`; baselines
  advance only after every row enqueues (at-least-once).
  `Outbox::MappingEmitter` publishes membership rows when sync establishes or
  upgrades a `SyncCollection` mapping.
- **Deletions (#220)**: `Disappearance::{Strategy,Finding,States,Detector}`
  with per-adapter strategies, complete-fetch/authorization guards,
  idempotent `source_metadata` markers; rationale in
  `docs/source-deletion-detection.md`.
- **Publisher (#221)**: end-of-sync `Outbox::WebPublisher.run!` plus the
  standalone `task_bridge:outbox:publish` / `publish_dry_run` tasks; response
  reduction (200 per-row reconcile, 413 halving, 429/5xx retry, 400/401/409/
  422 terminal), missing-result rows stay retryable, publication failures
  never fail the sync run.
- **Source metadata (#223)**: capability matrix
  (`docs/source-capability-matrix.md`) with per-adapter extraction status.
- **GitHub activity (#224)**: `Github::ActivityEmitter` publishes timeline
  facts as item-scoped observations with stable event-ID keys; the
  `last_successful_activity_sync_at` cursor advances only after every
  enqueue succeeds.
- **Calendar context (#225)**: read-only `GoogleCalendar::Service` via
  `task_bridge:sync_calendar`; `busy_only` default with explicit
  `event_details` opt-in; bounded lookback/lookahead; descriptions and
  attendee identities never published.
- **Privacy**: notes text never leaves through snapshots — only an HMAC
  `notes_digest` keyed by `TaskBridge.digest_key` (sync-note lines stripped);
  `notes_preview` remains omitted (the RDR's per-source export opt-in is
  deliberately not yet wired, so the safe default holds); responses and logs
  carry no credentials; failure detail is bounded text.

## Gap found and corrected in this audit

**No producer enqueued `sync_run` rows.** RDR #215 requires "one sync-run
summary per service run so TaskBridge Web can correlate item observations
with operational health." The infrastructure existed end to end (record kind,
key format, batch array, reconciler handling, model specs), but nothing in
the live flow emitted a row, so the fourth contract record kind never
reached TaskBridge Web.

Correction (bounded, no sync-behavior change):

- `Outbox::SyncRunEmitter` builds the RDR sync-run summary from the same
  `summarize_service_run` facts already persisted to `SyncServiceState`,
  publishing only `success`/`failed` runs (skipped/idle runs publish
  nothing, per the RDR; `partial` remains reserved). Errors carry
  `{class, message, retryable}` with `retryable: false` only for structural
  authentication failures; text fields are bounded.
- `lib/tasks/sync.rake` enqueues one row per service run with
  `sync_run_id: "sync-run-<sync_started_at>"`, exactly matching the
  `provenance.sync_run_id` that `Outbox::ObservationEmitter` stamps on the
  same run's item observations, so Web can correlate them.
- Emission is wrapped in `Outbox::IsolatedWrite`; `--pretend` remains a
  no-op through `OutboxEntry.enqueue`.
- Specs: `spec/services/outbox/sync_run_emitter_spec.rb` (schema, idempotent
  key, skipped/idle suppression, auth-failure retryable, identity fallback,
  text bounds) and `spec/tasks/sync_task_spec.rb` wiring coverage (success
  run enqueues; skipped run does not). The shared `stub_logger_summary`
  helper was aligned with `StructuredLogger#summarize_service_run`'s real
  status logic so skipped paths test faithfully.

## Residual observations (no action required to close)

- The committed Pact file rewrites interactions in execution order, which
  `--order random` full-suite runs may shuffle. Content is unaffected
  (interactions are an unordered set for provider verification); regenerate
  by running the contract spec file alone, per
  `docs/pact-consumer-contract-testing.md`.
- Standalone `item`-kind snapshot rows are supported by the publisher and
  pinned by the Pact, but the shipped producers embed the normalized
  snapshot in `snapshot_seen` observations instead; current state remains
  derivable on the Web side from discoveries plus transitions. Revisit only
  if Web needs denser current-state refresh than observations provide.
- RDR #215's open question (publishing `tentative`-confidence mappings
  during backfill) remains open by design; current behavior follows the
  RDR's safer default guidance.

## Conclusion

All epic acceptance criteria are met, every contract record kind now has a
producer, and the audit's single required correction is shipped with tests.
The epic can close.
