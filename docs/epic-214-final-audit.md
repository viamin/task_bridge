# Epic #214 Final Audit: Observation and Publication Layer

- Status: Complete — acceptance criteria met
- Date: 2026-10-10
- Epic: #214
- Decision record: `docs/rdr-215-taskbridge-observation-publication-contract.md` (Accepted)

This is the final audit of the epic umbrella. It verifies shipped behavior,
tests, and documentation directly against RDR #215 and the epic's acceptance
criteria — closed child issues were not treated as evidence on their own.

## Audit method

- Read RDR #215 and every shipped code path that produces or publishes
  outbox records, rather than trusting issue status.
- Ran the full suite (`bundle exec rspec`: 716 examples, 0 failures) and
  `bundle exec rubocop` (clean) before making any change.
- Compared each contract record kind, idempotency-key format, batch rule,
  retry/failure semantic, and privacy rule in the RDR against the producer
  and publisher code and its tests (including the committed Pact).

## Evidence by epic branch

| Epic branch | Shipped evidence |
|---|---|
| RDR / contract | `docs/rdr-215-...md` (Accepted, with follow-up decisions); wire shape pinned by `spec/pacts/taskbridge-taskbridge_web.json` and `spec/services/outbox/web_publisher/task_bridge_web_contract_spec.rb` |
| Identity/provenance | `sync_items`/`sync_collections` source-identity + mapping-provenance columns (`db/migrate/20260817094249_...`), `SyncMappingProvenance`, `Outbox::SourceIdentity`, `SyncBackfill::SourceProvenance` + `rake task_bridge:backfill_sync_provenance` |
| Source snapshots | `Base::SnapshotSerializer` + per-adapter `normalized_metadata`; documented in `docs/normalized-snapshot-field-support.md` |
| Observation outbox | `OutboxEntry` (unique idempotency key, retry backoff with jitter, immutable canonical payload) + `Outbox::IsolatedWrite` failure isolation |
| Change detection | `Outbox::SnapshotDiff` (one row per transition, sequenced keys) + `Outbox::ObservationEmitter` wired into `Base::SyncItem#refresh_from_external!`; baseline advances only after every row is enqueued |
| Deletions/disappearance | `Disappearance::Detector`/`Strategy`/`Finding`/`States` with per-adapter strategies and conservative guards; documented in `docs/source-deletion-detection.md` |
| Publisher | `Outbox::WebPublisher` (+ `Batch`, `Client`, `Response`, `Reconciler`, `Config`): versioned batches, per-row reconciliation, 413 halving, terminal/retryable classification, dry run; `rake task_bridge:outbox:publish` |
| Source metadata | `docs/source-capability-matrix.md` (per-adapter field audit) |
| GitHub activity | `Github::ActivityEmitter` with a decoupled activity-sync cursor (`SyncServiceState#record_activity_sync!`) |
| Calendar context | `GoogleCalendar::Service` — read-only, `busy_only` default with explicit `event_details` opt-in; `rake task_bridge:sync_calendar` |
| Backfills | `SyncBackfill::SourceProvenance` seeds identity/mapping provenance; unobserved items emit their baseline `snapshot_seen` (+ item row) on the next refresh, keeping backfill reruns idempotent |
| Privacy | Notes never leave as text: `notes_digest` is an HMAC-SHA256 of metadata-stripped notes keyed by `TaskBridge.digest_key`; `notes_preview` is not emitted (the per-source export setting does not exist yet, so the RDR default holds); calendar details require explicit opt-in |
| Operability | Retention-bounded outbox (`Outbox::Prune`), `--pretend` never writes, publication failure never fails sync, sync failures are isolated per service |

## Corrections made by this audit

The audit found the full publication pipeline supported all four RDR record
kinds, but only `observation` and `mapping` rows had producers:

1. **Sync-run summaries were never published.** RDR #215 requires one
   sync-run summary per service run ("TaskBridge should publish one sync-run
   summary per service run so TaskBridge Web can correlate item observations
   with operational health"). Added `Outbox::SyncRunEmitter` (wired into
   `rake task_bridge:sync` where `SyncServiceState.record_summary!` runs):
   publishes `success`/`failed`/`partial` runs with sanitized detail and the
   run's error, skips `skipped`/`idle` runs, derives the same
   `sync_run_id` ("sync-run-<sync_started_at>") that observation provenance
   carries, and is wrapped in `Outbox::IsolatedWrite`.
2. **Item current-state rows were never published.** The RDR's minimum
   normalized item snapshot ("the minimum current-state document TaskBridge
   can publish for a source item") had wire support (pinned by the Pact) but
   no producer; current state only traveled embedded in `snapshot_seen`
   observations, leaving TaskBridge Web to fold `source_changed` diffs.
   `Outbox::ObservationEmitter` now also enqueues an `item` row whenever the
   diff baseline advances (first observation or any change), with the
   contract-named optional fields (`started_at`, `parent`, `source_metadata`,
   `sync_collection`). Unchanged refreshes publish nothing new.

Both corrections are bookkeeping-only: `--pretend` writes nothing, outbox
write failures stay isolated from sync, and the pre-existing 716 examples
still pass unmodified (728 after adding the new coverage).

## Deliberate non-gaps

- **Tombstone item rows**: RDR says TaskBridge "may" publish a
  current-state snapshot with `is_deleted: true` after a tombstone; the
  `deleted` observation remains the required record. Not emitted.
- **Low-confidence mapping backfill**: RDR open question; the safer default
  is honored — `SyncBackfill::SourceProvenance` records provenance locally
  while published mappings keep their actual confidence values.
- **`partial` run status**: reserved by the RDR for runs that finish with
  some items failing; `Outbox::SyncRunEmitter` accepts it, but current sync
  flow records only `success`/`failed` per service.

## Acceptance criteria verification

- *Dependency-ordered implementation issues under the epic; first
  implementation issue depends on the approved RDR* — tracked in the #214
  issue tree (#215 RDR first, implementation issues reference it in code
  comments and docs).
- *Existing sync behavior remains compatible* — full suite green before and
  after this audit; emitters are isolated post-sync bookkeeping.
- *TaskBridge can publish normalized, idempotent facts that TaskBridge Web
  can store and reason over without source-specific API knowledge* — all
  four contract record kinds now have producers; the committed Pact pins the
  v1 wire shape for provider verification.

## Verification commands

- `bundle exec rspec` — 728 examples, 0 failures
- `bundle exec rubocop` — no offenses
