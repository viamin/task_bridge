# Epic #214 Final Audit: Observation and Publication Layer

- Epic: #214
- Contract: RDR #215 (`docs/rdr-215-taskbridge-observation-publication-contract.md`)
- Date: 2026-10-10
- Outcome: **Complete.** All epic branches verified against the approved RDR
  with shipped code, passing tests, and documentation. One bounded gap was
  found and corrected during this audit (sync-run summary emission, below).

## Audit method

Closed child issues were not treated as evidence. Each branch below was
verified by reading the shipped implementation, running its specs, and
checking its documentation against the RDR #215 contract sections.

- Test suite: `bundle exec rspec` — 724 examples, 0 failures (716 before
  this audit; the 8 added examples cover the correction below).
- Lint: `bundle exec rubocop` — 160 files inspected, no offenses detected.
- Pact consumer contract:
  `spec/services/outbox/web_publisher/task_bridge_web_contract_spec.rb`
  pins the HTTP request/response shape against the committed pact.

## Verification by epic branch

| Branch | Evidence |
|---|---|
| RDR / contract | `docs/rdr-215-...md` (Accepted). Batch shape, four record kinds, idempotency-key format, timestamp rules, tombstones, HTTP status guidance, and privacy constraints are all implemented as specified. |
| Identity / provenance | `Outbox::SourceIdentity`, `Base::SyncItem#capture_source_identity` (service name/instance/type, external ID, URL, first/last observed), `SyncMappingProvenance` priority ladder, `SyncCollection#update_mapping_provenance!`, `SyncBackfill::SourceProvenance` + `rake task_bridge:backfill_sync_provenance`. Specs: `sync_mapping_provenance_spec.rb`, `backfill_sync_provenance_task_spec.rb`. |
| Source snapshots | `Base::SnapshotSerializer` (versioned, source-agnostic; notes published only as an HMAC `notes_digest`, never content) plus per-adapter `normalized_metadata` overrides; capability matrix in `docs/normalized-snapshot-field-support.md`. Specs: `snapshot_serializer_spec.rb`, per-adapter item specs. |
| Observation outbox | `OutboxEntry` model + migration (unique idempotency key, pending/delivered/failed, exponential backoff with jitter, `retry!`), `Outbox::IsolatedWrite` (bounded retry; sync never fails from outbox writes), `Outbox::Prune` + `rake task_bridge:outbox:prune` (bounded queue; TaskBridge Web owns history). Specs: `outbox_entry_spec.rb`, `outbox_entry_indexes_spec.rb`, `prune_spec.rb`, `isolated_write_spec.rb`. |
| Change detection | `Outbox::SnapshotDiff` (single-field transitions, timestamp/array normalization) + `Outbox::ObservationEmitter` wired into `Base::SyncItem#refresh_from_external!`; baseline advances only after every row is enqueued (at-least-once). Specs: `snapshot_diff_spec.rb`, `observation_emitter_spec.rb`. |
| Deletions / disappearance | `Disappearance::{Strategy,Finding,States,Detector}` with conservative per-adapter strategies (Keep/Reminders full-list; OmniFocus/Asana verified; GitHub/Google Tasks/Instapaper/Reclaim disabled with reasons), marker-based idempotency, no local row deletion. Docs: `docs/source-deletion-detection.md`. Specs: `detector_spec.rb` + five per-adapter deletion-detection specs. |
| Publisher | `Outbox::WebPublisher` + `Batch`/`Client`/`Response`/`Reconciler`/`Config`: authenticated HTTP push, per-row reconciliation of partial-success responses, 413 batch halving, retryable/terminal classification, exponential backoff, dry-run NDJSON preview, disabled-by-default config, end-of-run publication that never changes sync exit status. Wired via `rake task_bridge:sync` and `rake task_bridge:outbox:publish`. Specs: `web_publisher/**/*_spec.rb` incl. Pact contract. |
| Source metadata gaps | Adapter-specific facts in `normalized_metadata` per `docs/source-capability-matrix.md`; `docs/normalized-snapshot-field-support.md` records per-adapter field coverage. |
| GitHub activity | `Github::ActivityEmitter` (timeline + review events, derived `opened`, stable source-event IDs, isolated writes) with a cursor (`SyncServiceState#record_activity_sync!`) that advances only when every emission completed. Specs: `activity_emitter_spec.rb`, cursor specs in `sync_task_spec.rb`. |
| Calendar context | Read-only `GoogleCalendar::Service` + `rake task_bridge:sync_calendar`; `busy_only` privacy default with explicit `event_details` opt-in, bounded read window, deterministic digest-based idempotency keys. Specs: `google_calendar/service_spec.rb`. |
| Backfills | Provenance backfill (`SyncBackfill::SourceProvenance`); baseline observation backfill is safe to rerun because first observation of an item emits `snapshot_seen` with a deterministic key, and dry-run NDJSON export previews batches before sending (RDR §Migration). |
| Tests / observability / privacy / docs | 724 passing examples; no notes content, tokens, cookies, or raw provider payloads leave TaskBridge (HMAC digests; sanitized sync-run detail/errors; busy-only calendar default); docs set: RDR, deletion detection, capability matrix, snapshot field support, Pact testing guide. |

## Gap found and corrected during this audit

**Sync-run summaries had no producer.** The RDR §"Sync-Run Summary
Schema" requires one summary per service run so TaskBridge Web can
correlate item observations with operational health. The downstream path
was complete (`OutboxEntry::RECORD_KINDS`, `Outbox::IdempotencyKey`, and
`Outbox::WebPublisher::Batch` all support `sync_run`), but nothing ever
enqueued such rows, leaving the fourth contract record kind unreachable.

Correction (bounded, in this change):

- `Outbox::SyncRunEmitter` builds one RDR-conformant row per `success` or
  `failed` service run — `sync_run_id` in the detector's run-scope format,
  service-qualified identity matching `Outbox::SourceIdentity`, normalized
  `*_at` timestamps from the run summary, `touched_collection_ids`,
  sanitized/truncated `detail`, and a structured `error` whose `retryable:
  true` states the retry policy actually used (every failed service is
  retried on the next scheduled run). Skipped and idle runs publish
  nothing, per the RDR.
- Wired into `rake task_bridge:sync` immediately after
  `SyncServiceState.record_summary!`, wrapped in `Outbox::IsolatedWrite`
  so an outbox failure can never change the run result it summarizes.
- Covered by `spec/services/outbox/sync_run_emitter_spec.rb` (7 examples)
  plus a wiring test in `spec/tasks/sync_task_spec.rb`.

## Acceptance criteria check

1. *Dependency-ordered implementation issues under the epic, first depending
   on the approved RDR* — issue tree is GitHub-side; the RDR (#215) is
   Accepted and referenced by every implementation doc/spec audited here.
2. *Existing sync behavior remains compatible* — publication is opt-in
   (`task_bridge.web.enabled: false` by default), isolated
   (`Outbox::IsolatedWrite`), and end-of-run only; the full pre-existing
   suite still passes unchanged (716/716 baseline examples).
3. *TaskBridge can publish normalized, idempotent facts TaskBridge Web can
   store and reason over without source-specific API knowledge* — verified:
   observations (`snapshot_seen` carrying the full normalized snapshot,
   `source_changed` field transitions, `deleted` tombstones), `mapping`
   memberships, and `sync_run` summaries all flow from normalized snapshots
   through the deduplicating outbox to the versioned, authenticated batch
   endpoint with per-row idempotency keys. Standalone `item` snapshot rows
   remain contract-supported end-to-end (`OutboxEntry::RECORD_KINDS`,
   `Outbox::IdempotencyKey`, `Batch::ARRAY_BY_RECORD_KIND`) but are not
   produced: current state already reaches TaskBridge Web through the
   snapshot embedded in every `snapshot_seen` observation plus subsequent
   field transitions, which is the history-preserving path the RDR
   prefers (§Rejected Alternatives rejects snapshot-only publication).

No required gaps remain from this audit.
