# Normalized Snapshot Field Support

- Issue: #217
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
| due_at / due_date  | yes       | yes   | no     | yes (date)    | yes       | yes     | no         | no          |
| start_at / start_date | yes    | yes   | no     | no            | yes       | yes     | no         | no          |
| flagged            | yes       | yes   | no     | no            | no        | no      | no         | no          |
| priority           | no        | no    | no     | no            | yes       | no      | no         | no          |
| estimated_minutes  | yes       | no    | no     | no            | no        | no      | yes (computed) | no      |
| project            | yes       | yes   | yes (repo) | no        | yes (mapped list) | no | yes (configured) | yes (note title) |
| tags               | yes       | yes   | yes (labels) | no      | no        | yes     | yes (static) | no        |
| assignee           | no        | yes   | no     | no            | no        | no      | no         | no          |
| sub_item_count / sub_item_keys | yes | yes | no  | no            | no        | no      | no         | yes         |
| source_url         | yes       | yes   | yes    | yes           | no        | no      | yes        | no          |
| source_created_at  | yes       | yes   | yes    | no            | yes       | yes     | yes        | no          |
| source_updated_at  | yes       | yes   | yes    | yes           | yes       | yes     | yes        | yes         |

## Source-specific `metadata`

- **Asana**: `section` (Asana section name; not a general project/list concept).
- **GitHub**: `number` (issue/PR number), `pull_request` (PR flag).
- **Reminders**: `list` (containing Reminders list name).
- **Reclaim**: `category` (`PERSONAL`/`WORK`), `time_required`, `time_spent`,
  `time_remaining`, `minimum_chunk_size`, `maximum_chunk_size`,
  `always_private` — Reclaim's chunk-based scheduling model doesn't reduce to
  a single `estimated_minutes` value.
- **Instapaper**: `folder` (reading-list folder, distinct from `project`,
  which is a fixed configured value for all articles).
- **Google Keep**: `stable_external_id_embedded` (whether the external ID
  came from Keep's embedded marker vs. a freshly generated UUID).
- **OmniFocus**, **Google Tasks**: no adapter-specific metadata today; all
  currently-read fields fit the common schema.

## Known gaps

- `notes_preview` is intentionally **not** emitted by any adapter today. The
  publication contract (#215) requires note export to be opt-in per source via
  TaskBridge configuration, and that setting does not exist yet. Until it
  lands, omitting notes keeps full source note bodies from leaking through
  the snapshot. When the setting is added, the field should be exposed as
  `notes_preview` (matching the contract) rather than `notes`.
- `status` only ever resolves to `open` or `completed`. No adapter currently
  exposes an explicit "dropped"/abandoned state (OmniFocus models this via
  AppleScript's `dropped`/`effectively_dropped` properties, but TaskBridge
  does not read them today).
- `is_deleted` is always `false`. `Base::SyncItem` does not yet model
  deletion; tombstone/deletion semantics are left for the publication work
  under #214.
- `source.service_instance` is only populated for items that have gone
  through `capture_source_identity` (i.e. `observe_source!` /
  `refresh_from_external!`). A freshly constructed, unsaved item may have a
  `nil` `service_instance` even though `service_type` and `external_id` are
  already known.

## `source.service_type` format

`source.service_type` carries the stable adapter-family identifier from the
publication contract (#215), not the display name returned by
`Base::SyncItem#provider`. The serializer applies
`Base::Service.service_identifier_for(provider)` so each value is the
class-name in snake_case (e.g. `asana`, `google_tasks`, `omnifocus`,
`github`, `instapaper`, `reminders`, `reclaim`, `google_keep`). The instance
component (when present) belongs only in `source.service_instance` — see
`app/services/base/snapshot_serializer.rb`.
