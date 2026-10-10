# Normalized Snapshot Field Support

- Issue: #217 (enriched by #223 — see `docs/source-capability-matrix.md` for
  the full per-source capability audit)
- Depends on: #215 (contract shape, see
  `docs/rdr-215-taskbridge-observation-publication-contract.md`), #216 (source
  identity/provenance columns)

`Base::SyncItem#normalized_snapshot` (implemented by `Base::SnapshotSerializer`)
produces a versioned, deterministic hash of an item's current state without
branching on the source service. Fields common to several adapters are
promoted to the top level; everything else is source-specific and lives
under `metadata`, supplied per adapter via `normalized_metadata`.

This table records what each adapter currently populates for the top-level
fields, and which source-specific facts live in `metadata`. "no" means the
source does not expose the concept today, not that it never could.

| Field              | OmniFocus | Asana | GitHub | Google Tasks | Reminders | Reclaim | Instapaper | Google Keep |
|--------------------|-----------|-------|--------|---------------|-----------|---------|------------|-------------|
| title              | yes       | yes   | yes    | yes           | yes       | yes     | yes        | yes         |
| status/completed   | yes       | yes   | yes    | yes           | yes       | yes     | yes        | yes         |
| completed_at       | yes       | yes   | yes (closed_at) | yes (completed) | yes (completed_on) | no  | no        | no          |
| due_at / due_date  | yes       | yes   | no     | yes (date)    | yes       | yes     | no         | no          |
| start_at / start_date | yes    | yes   | no     | no            | yes       | yes     | no         | no          |
| flagged            | yes       | yes   | no     | no            | no        | no      | no         | no          |
| priority           | no        | no    | no     | no            | yes (mapped label) | no | no        | no          |
| estimated_minutes  | yes       | no    | no     | no            | no        | no      | yes (computed) | no      |
| project            | yes       | yes   | yes (repo) | no        | yes (mapped list) | no | yes (configured) | yes (note title) |
| tags               | yes       | yes   | yes (labels) | no      | no        | yes     | yes (static) | no        |
| assignee           | no        | yes   | yes (login) | no       | no        | no      | no         | no         |
| sub_item_count / sub_item_keys | yes | yes | no  | no            | no        | no      | no         | yes         |
| source_url         | yes       | yes   | yes    | yes           | no        | no      | yes        | no          |
| source_created_at  | yes       | yes   | yes    | no            | yes       | yes     | yes        | no          |
| source_updated_at  | yes       | yes   | yes    | yes           | yes       | yes     | yes        | yes         |

## Source-specific `metadata`

- **Asana**: `section` (Asana section name), `section_gid`, `project_gid`
  (the matched membership's identifiers), `workspace_gid`, `workspace_name`,
  `assignee_name`.
- **GitHub**: `number` (issue/PR number), `pull_request` (PR flag), `draft`
  (PR draft state, PRs only), `repository` (`owner/name`), `author` (issue
  author login), `assignees` (assignee logins), `milestone` (title),
  `comments_count`.
- **Google Tasks**: `list`, `list_id` (containing task list identity, when
  known from the service), `parent` (parent task id), `web_view_link` (web
  UI deep link).
- **Reminders**: `list` (containing Reminders list name), `priority_value`
  (raw AppleScript priority integer; the mapped `none`/`low`/`medium`/
  `high` label is published as the top-level `priority`).
- **Reclaim**: `category` (`PERSONAL`/`WORK`), `status` (Reclaim's own
  scheduling status, e.g. `SCHEDULED`/`IN_PROGRESS`/`COMPLETE` — distinct
  from the snapshot's open/completed/dropped status), `event_sub_type`,
  `at_risk`, `time_required`, `time_spent`, `time_remaining`,
  `minimum_chunk_size`, `maximum_chunk_size`, `always_private` — Reclaim's
  chunk-based scheduling model doesn't reduce to a single
  `estimated_minutes` value.
- **Instapaper**: `folder` (reading-list folder, distinct from `project`,
  which is a fixed configured value for all articles), `progress` (0-1
  reading progress), `starred`.
- **Google Keep**: `stable_external_id_embedded` (whether the external ID
  came from Keep's embedded marker vs. a freshly generated UUID),
  `note_id` (containing note identity), `list_path` (position in the nested
  list structure).
- **OmniFocus**: no adapter-specific metadata today; all currently-read
  fields fit the common schema.

## Known gaps

- The #223 enrichment pass only *added* top-level optional fields
  (`completed_at` for GitHub/Google Tasks, `assignee` for GitHub) and new
  keys under `metadata`. The one value change is Reminders `priority`, which
  now carries the mapped `none`/`low`/`medium`/`high` label instead of the
  raw AppleScript integer (kept in `metadata.priority_value`); no snapshot
  carrying the old value has ever been published. `VERSION` stays `1` under
  the payload versioning scheme: consumers must tolerate new keys within a
  version.
- `notes_preview` is intentionally **not** emitted by any adapter today. The
  publication contract (#215) requires note export to be opt-in per source via
  TaskBridge configuration, and that setting does not exist yet. Until it
  lands, omitting notes keeps full source note bodies from leaking through
  the snapshot. When the setting is added, the field should be exposed as
  `notes_preview` (matching the contract) rather than `notes`.
  `notes_digest` — a keyed SHA-256 digest (HMAC-SHA256, keyed by the
  deployment's `task_bridge.digest_key` setting, falling back to the app's
  `secret_key_base`) of the metadata-stripped notes content — *is* emitted
  so change detection (#219) and consumers can observe note edits without
  the text ever leaving TaskBridge. It is one-way: comparing digests shows
  whether notes are identical or different, nothing more. Because it is
  keyed, a published digest cannot be matched against offline guesses of
  note text; digests are only comparable within one deployment, and
  rotating the key only re-baselines the digest.
- `status` only ever resolves to `open` or `completed`. No adapter currently
  exposes an explicit "dropped"/abandoned state (OmniFocus models this via
  AppleScript's `dropped`/`effectively_dropped` properties, but TaskBridge
  does not read them today).
- `is_deleted` is always `false`. `Base::SyncItem` does not yet model
  deletion; tombstone/deletion semantics are left for the publication work
  under #214.

## `source` identity format

`source.service_type` carries the stable adapter-family identifier from the
publication contract (#215), not the display name returned by
`Base::SyncItem#provider`. The serializer applies
`Base::Service.service_identifier_for(provider)` so each value is the
class-name in snake_case (e.g. `asana`, `google_tasks`, `omnifocus`,
`github`, `instapaper`, `reminders`, `reclaim`, `google_keep`).

`source.service_instance` is **always** populated — including for a
freshly constructed item that has not gone through
`capture_source_identity` — so consumers must not code for a nilable
value. `Outbox::SourceIdentity` embeds the `service_type` followed by the
captured instance segment when one exists (`asana:work`,
`omnifocus:default`), and yields the bare `service_type` (`asana`)
otherwise; the per-instance component therefore belongs only in
`source.service_instance`, never in `source.service_type`. Like `item_key`
and idempotency keys, `service_instance` is opaque: consumers must not
parse it by splitting on `:` because segments may themselves contain
colons.

## Observation emission (#219)

Sync flows emit normalized observation and mapping rows into the local
outbox (#218) by diffing snapshots. Emission is write-only bookkeeping: it
runs after a refresh has already been observed and never changes sync
semantics, return values, or error handling. `--pretend` runs never write
outbox rows or advance the diff baseline.

- **Baseline**: the last published snapshot per item is stored in
  `sync_items.last_snapshot` (timestamps rendered as ISO 8601 UTC so JSON
  round-trips stay diff-stable).
- **Source observations** (`Outbox::ObservationEmitter`, hooked into
  `Base::SyncItem#refresh_from_external!`): a first observation emits
  `snapshot_seen` (with the full snapshot embedded); later refreshes emit
  one `source_changed` row per field transition via `Outbox::SnapshotDiff`.
  The diffed fields are `SnapshotDiff::OBSERVED_FIELDS` plus the
  containment metadata keys (`metadata.folder`, `metadata.list`,
  `metadata.list_id`, `metadata.section`). Volatile, derived, identity, and
  provenance-only fields are excluded, so re-observation without a real
  change emits nothing.
- **Created representations** (`Base::Service#persist_created_sync_data_for`):
  a cross-service representation created by sync emits its `snapshot_seen`
  row with `provenance.detected_by: created_by_sync` unless its own refresh
  already published the discovery.
- **Mappings** (`Outbox::MappingEmitter`, hooked into
  `Base::Service#persist_sync_collection_for`): a `representation_membership`
  row is published for each item that joins a `SyncCollection`, and for
  every member when the collection's mapping provenance meaningfully
  changes (for example `title_fallback` upgrading to `source_sync_id`).
  Internal confidence values map to the contract's vocabulary
  (high → `confirmed`; medium/low → `tentative`).
- **Key uniqueness**: when one observation yields several field transitions,
  each row's idempotency key carries a sequence segment
  (`Outbox::IdempotencyKey`), per the RDR #215 rule for colliding observed
  timestamps. The baseline is only advanced after every row is enqueued, so
  a failed enqueue can re-detect a transition (at-least-once) but never
  silently swallows one.

## Sync-run summaries

`Outbox::SyncRunEmitter` (hooked into the `task_bridge:sync` rake task,
alongside `SyncServiceState.record_summary!`) publishes one `sync_run` row
per service run so TaskBridge Web can correlate item observations with
operational health. The row reuses the facts `StructuredLogger` already
summarizes, renamed to the contract's explicit `*_at` timestamp fields
(`last_attempted` → `last_attempted_at`, and so on). Skipped and idle
services publish nothing. Failed runs carry `error` with
`retryable: true`, matching the run-level retry policy TaskBridge actually
uses (every failed service is retried on the next scheduled sync). The
`sync_run_id` mirrors `Disappearance::Detector`'s run scope
(`sync-run-<timestamp>-<service>`), and emission is isolated bookkeeping:
a failed write never changes the run's own result.
