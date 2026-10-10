# Epic #214 Final Audit: TaskBridge as the Deterministic Observation and Publication Layer

- Status: Complete — no required gaps remain
- Date: 2026-10-10
- Parent: #214
- Decision record: RDR #215
  (`docs/rdr-215-taskbridge-observation-publication-contract.md`)
- Method: shipped behavior, tests, and documentation were verified directly
  against RDR #215 and the epic's acceptance criteria. Closed child issues
  were treated as claims, not evidence; every capability below was
  re-confirmed in code and specs. Bounded corrections applied during this
  audit are listed under "Corrections".

## Acceptance criteria verdict

| Criterion | Verdict | Evidence |
|---|---|---|
| Dependency-ordered implementation issues under the epic | Met | RDR #215 accepted first; follow-up issues (#216-#223, #219-#221, #220, #224, #225, #250) are cross-referenced in the docs and code comments below |
| First implementation issue depends on the approved RDR | Met | `OutboxEntry` and every emitter cite RDR #215; the contract predates storage (`docs/rdr-215-...`, status: Accepted) |
| Existing sync behavior remains compatible | Met | All emitters run as bookkeeping behind `Outbox::IsolatedWrite` and the `--pretend` no-op in `OutboxEntry.enqueue`; publication runs after sync and never changes exit status (`lib/tasks/sync.rake`, `spec/tasks/sync_task_spec.rb`) |
| TaskBridge publishes normalized, idempotent facts Web can store without source-specific API knowledge | Met | All four contract record kinds now have producers (see below); the wire shape is pinned by the committed Pact (`spec/pacts/taskbridge-taskbridge_web.json`, verified by `spec/services/outbox/web_publisher/task_bridge_web_contract_spec.rb`) |

## Verified capability inventory

- **Contract (RDR #215)**: versioned batch contract for
  `POST /api/task_bridge/v1/ingestion/batches` implemented in
  `Outbox::WebPublisher::Batch` with required headers, per-row
  `idempotency_key` + `contract_version`, and all four record arrays.
- **Identity/provenance (#216)**: `sync_items.source_*` columns captured in
  `Base::SyncItem#capture_source_identity`; `Outbox::SourceIdentity` shared
  by every record kind; `SyncMappingProvenance` ranks mapping evidence;
  `task_bridge:backfill_sync_provenance` seeds identity and mapping
  provenance for existing rows (`SyncBackfill::SourceProvenance`).
- **Normalized snapshots (#217/#223)**: `Base::SnapshotSerializer` plus
  per-adapter `normalized_metadata`; coverage documented in
  `docs/normalized-snapshot-field-support.md` and
  `docs/source-capability-matrix.md`. Notes are published only as a keyed
  `notes_digest`; `notes_preview` is never emitted (the per-source opt-in
  from RDR #215's privacy rules does not exist yet).
- **Observation outbox (#218)**: `OutboxEntry` with immutable canonical
  payload, deterministic keys (`Outbox::IdempotencyKey`), retry backoff with
  jitter, retention pruning (`Outbox::Prune`, `task_bridge:outbox:prune`).
- **Change detection (#219)**: `Outbox::SnapshotDiff` (one row per
  transition, sequenced keys) emitted from
  `Base::SyncItem#refresh_from_external!` via `Outbox::ObservationEmitter`;
  mapping facts via `Outbox::MappingEmitter` from `Base::Service`.
- **Deletions/disappearance (#220)**: `Disappearance::Detector` with
  per-adapter strategies; states, guards, and rationale documented in
  `docs/source-deletion-detection.md`; tombstones are explicit
  `event_type: deleted` observations.
- **Publisher (#221/#250)**: `Outbox::WebPublisher` — version-homogeneous
  batches, 413 halving, per-row reconciliation, terminal/retryable
  classification, dry-run NDJSON preview, and end-of-sync publication
  isolated from sync results; Pact consumer contract tests committed.
- **GitHub activity (#224)**: `Github::ActivityEmitter` publishes timeline
  facts (comments, labels, assignments, milestones, renames, merges) with a
  dedicated activity-sync cursor on `SyncServiceState`.
- **Calendar context (#225)**: read-only `GoogleCalendar::Service`
  (`task_bridge:sync_calendar`), busy-only by default with an explicit
  `event_details` opt-in; failures cannot affect task sync.
- **Sync-run summaries**: `Outbox::SyncRunEmitter` publishes one summary
  per `success`/`failed` service run (skipped/idle never publish), with
  sanitized detail and the run's error/retryability.
- **Backfills**: `task_bridge:outbox:backfill` (`SyncBackfill::Baseline`)
  seeds one current-state `item` snapshot per known source item and mapping
  rows for confirmed memberships, with deterministic keys so reruns are
  no-ops. Baseline `snapshot_seen` observations seed themselves on each
  item's next refresh (`last_snapshot` starts empty).

## Corrections applied by this audit

Four gaps were found against the approved RDR and fixed as bounded
corrections:

1. **No sync-run summary producer** (RDR: "TaskBridge should publish one
   sync-run summary per service run"). The `sync_run` record kind,
   idempotency key format, and batch array existed and were tested, but
   nothing enqueued rows. Added `Outbox::SyncRunEmitter`, wired into
   `task_bridge:sync` next to `SyncServiceState.record_summary!`.
2. **Divergent `sync_run_id` formats** — observation provenance used
   `sync-run-<ISO8601>` while tombstones used the RDR's
   `sync-run-<compact>-<service>`, so TaskBridge Web could not correlate
   rows with run summaries. Added `Outbox::SyncRunId` as the single format
   (RDR example shape) and pointed `Outbox::ObservationEmitter`,
   `Disappearance::Detector`, and `Outbox::SyncRunEmitter` at it.
3. **Tombstone identity broke the identity spine** — tombstones carried
   `service_instance: <ServiceName>` (e.g. `"Asana"`) while every other
   record kind carried `Outbox::SourceIdentity`'s `"asana"`-form, splitting
   one source record into two identities in Web. `Disappearance::Detector`
   now builds its source payload from `Outbox::SourceIdentity`.
4. **No producer for the `item` record kind / RDR backfill bullets** ("one
   current-state item snapshot per known source item; mapping rows for
   known sync_collection memberships"). Added `Outbox::ItemEmitter` and
   `SyncBackfill::Baseline` (`task_bridge:outbox:backfill`), publishing
   only high-confidence (confirmed) mappings per the RDR open question's
   documented safer default.

## Documented, non-blocking limitations

These are explicit capability decisions or open questions recorded in the
docs, not epic blockers:

- The RDR open question on backfilling low-confidence (`tentative`)
  mappings remains open; backfill withholds them.
- `notes_preview` export per source is not yet configurable, so it is
  never emitted.
- Google Tasks `deleted`/`hidden` flags and GitHub
  sub-issues/`state_reason` are not read yet
  (`docs/source-capability-matrix.md`).
- The RDR's `partial` run status is reserved; TaskBridge records only
  `success` and `failed` runs today.

## Verification

- `bundle exec rubocop` — no offenses.
- `bundle exec rspec` — 741 examples, 0 failures (includes the new
  emitter, backfill, sync-task, and identity-spine specs added by this
  audit).
- Pact consumer contract regenerated and verified:
  `spec/services/outbox/web_publisher/task_bridge_web_contract_spec.rb`.
