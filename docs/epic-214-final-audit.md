# Epic #214 Final Audit: Observation and Publication Layer

- Status: Complete — one required gap found and corrected
- Date: 2026-10-10
- Epic: #214
- Decision record: RDR #215 (`docs/rdr-215-taskbridge-observation-publication-contract.md`)

## Method

Verified shipped behavior, tests, and documentation directly against RDR
#215 and the epic's acceptance criteria — implementation evidence only, not
closed child issues. Full suite (`bundle exec rspec`) and `bundle exec
rubocop` run green before and after the correction.

## Evidence by epic area

| Epic area | Evidence |
| --- | --- |
| RDR / contract | `docs/rdr-215...md` accepted; Pact consumer contract pins the v1 wire shape (`spec/services/outbox/web_publisher/task_bridge_web_contract_spec.rb`, `spec/pacts/taskbridge-taskbridge_web.json`) |
| Identity / provenance | `Outbox::SourceIdentity`, `SyncMappingProvenance`, `SyncBackfill::SourceProvenance` + `task_bridge:backfill_sync_provenance`; specs in `spec/models/sync_mapping_provenance_spec.rb`, `spec/services/outbox/idempotency_key_spec.rb` |
| Source snapshots | `Base::SnapshotSerializer` + `normalized_snapshot` per `Base::SyncItem`; `spec/services/base/snapshot_serializer_spec.rb`; field coverage in `docs/normalized-snapshot-field-support.md` |
| Observation outbox | `OutboxEntry` model + `outbox_entries` migration/indexes; `spec/models/outbox_entry_spec.rb`, `spec/models/outbox_entry_indexes_spec.rb`; `Outbox::Prune` + `task_bridge:outbox:prune` |
| Change detection | `Outbox::ObservationEmitter` + `Outbox::SnapshotDiff` wired into `Base::SyncItem#refresh_from_external!`; `spec/services/outbox/observation_emitter_spec.rb` |
| Deletions / disappearance | `Disappearance::Detector` + per-adapter strategies (`docs/source-deletion-detection.md`); per-adapter `deletion_detection_spec.rb` files |
| Publisher | `Outbox::WebPublisher` (+ `Client`/`Batch`/`Reconciler`/`Response`/`Config`): idempotency keys, exponential backoff with jitter, 413 batch halving, partial-success reconciliation, terminal-failure isolation; `task_bridge:outbox:publish` wired as end-of-run bookkeeping in `lib/tasks/sync.rake` |
| Source metadata | `docs/source-capability-matrix.md`, `docs/normalized-snapshot-field-support.md` |
| GitHub activity | `Github::ActivityEmitter` + decoupled activity cursor (`SyncServiceState.record_activity_sync!`); `spec/services/github/activity_emitter_spec.rb` |
| Calendar context | `GoogleCalendar::Service` read-only, busy-only by default with explicit `event_details` opt-in; `task_bridge:sync_calendar`; `spec/services/google_calendar/service_spec.rb` |
| Backfills | `task_bridge:backfill_sync_provenance` seeds provenance/mappings; dry-run NDJSON export for backfill preview (`task_bridge:outbox:publish_dry_run`) |
| Privacy | Notes never leave as text (keyed `notes_digest` only); calendar busy-only default; publisher logs never carry the API key or row payloads |

## Gap found and corrected

**No producer for `sync_run` rows.** RDR #215 requires "one sync-run
summary per service run so TaskBridge Web can correlate item observations
with operational health." The record kind, idempotency-key format, batch
array, and Pact examples all existed, but nothing enqueued the rows, so
operational-health facts would never reach TaskBridge Web.

Correction (bounded, this audit):

- `Outbox::SyncRunEmitter` maps the `StructuredLogger` run summary onto the
  contract's sync-run schema (explicit `*_at` timestamps, `touched_collection_ids`,
  `error` with `retryable: true` matching the next-scheduled-run retry
  policy). Skipped/idle services publish nothing, per the RDR.
- Wired into `lib/tasks/sync.rake` next to `SyncServiceState.record_summary!`
  as isolated bookkeeping that cannot change the run's own result.
- Specs: `spec/services/outbox/sync_run_emitter_spec.rb` (8 examples) and a
  task-level wiring example in `spec/tasks/sync_task_spec.rb`.

## Non-gaps (verified decisions, not omissions)

- `item` snapshots are published as `snapshot_seen` observations with the
  full snapshot embedded (documented in
  `docs/normalized-snapshot-field-support.md`), rather than as separate
  `items` rows; current state is therefore delivered over the same
  idempotent path without a second producer.
- `OutboxEntry#retry!` provides the scripted terminal-failure replay the
  RDR's failure semantics require.
- Notes export remains configuration-gated and disabled by default; no
  per-source notes export setting exists yet, and no notes text is emitted.

## Outcome

All RDR #215 record kinds now have producers and end-to-end publication:
observations (snapshot/diff/tombstone), mappings, and sync-run summaries,
pushed over the versioned authenticated HTTP contract with retries and
idempotency. Acceptance criteria of #214 are met with the correction above;
no required gaps remain.
