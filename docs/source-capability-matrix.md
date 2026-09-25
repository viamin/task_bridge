# Source Capability Matrix

- Issue: #223
- Parent: #214
- Depends on: #217 (`Base::SyncItem#normalized_snapshot`, see
  `docs/normalized-snapshot-field-support.md`)

This matrix records, per source adapter, which productivity-relevant fields
the upstream API exposes and whether TaskBridge currently extracts them into
the normalized snapshot. It exists so downstream consumers (TaskBridge Web)
know what facts are available without each adapter re-answering the question.

Legend:

- **yes** — extracted and published in `normalized_snapshot` (top level or
  under `metadata`)
- **partial** — the source exposes the concept with limitations, or
  TaskBridge publishes a subset of what is available
- **no** — the source does not expose the concept through the interface
  TaskBridge uses (AppleScript dictionary or REST payload)

TaskBridge only publishes observed facts. It never ranks, recommends, or
infers what to work on (#214); mappings below (e.g. the Reminders priority
label) translate the source's own enumerations, not TaskBridge judgments.

## Matrix

| Capability | OmniFocus | Asana | GitHub | Google Tasks | Reminders | Reclaim | Instapaper | Google Keep |
|---|---|---|---|---|---|---|---|---|
| Due date/time | yes | yes (date + time) | no | yes (date only) | yes (all-day date; timed date not extracted) | yes | no | no |
| Defer/start date/time | yes (`defer_date`) | yes (premium field) | no | no | partial (`remind_me_date`, a notification time, maps to `start_date`) | yes (`snoozeUntil`) | no | no |
| Estimated duration | yes (`estimated_minutes`) | no | no | no | no | yes, as 15-minute chunks in `metadata` | yes (computed read time, when full text is fetched) | no |
| Priority/flag | flag yes | flag via `hearted` | no | no | yes (mapped `none`/`low`/`medium`/`high`; raw value in `metadata`) | no (source `priority` not read) | no | no |
| Project/area/list/section | yes (project name) | yes (project + section names and gids, workspace gid/name in `metadata`) | yes (repo short name; full `owner/name` in `metadata`) | yes (list title/id in `metadata`) | yes (list name in `metadata`; `project` via configured list map) | no | yes (folder in `metadata`; configured `project`) | yes (note title; note id + list path in `metadata`) |
| Tags/contexts/labels | yes | yes (tags + section names) | yes (labels) | no | no (not exposed via AppleScript) | no native tags; TaskBridge-applied defaults | yes (static default tag) | no |
| Assignee/owner | no | yes (assignee gid; name in `metadata`) | yes (assignee login; assignees/author in `metadata`) | no | no | no | no | no |
| Completion state/timestamps | yes (`completed`, `completed_at`) | yes (`completed`, `completed_at`) | yes (state; `closed_at` maps to `completed_at`) | yes (status; `completed` timestamp maps to `completed_at`) | yes (`completed`, `completed_on`) | yes (derived from `timeChunksRemaining`) | yes (folder `unread` vs archived) | yes (`checked`) |
| Creation timestamp | yes (`creation_date`) | yes (`created_at`) | yes (`created_at`) | no (API does not expose one) | yes (`creation_date`) | yes (`created`) | yes (`time`) | no (only `update_time` exposed) |
| Modification timestamp | yes (`modification_date`) | yes (`modified_at`) | yes (`updated_at`) | yes (`updated`) | yes (`modification_date`) | yes (`updated`) | yes (`progress_timestamp`) | yes (`update_time`) |
| URL/deep link | yes (`omnifocus:///task/<id>`) | yes (`permalink_url`) | yes (`html_url`) | yes (API `self_link` as `url`; web UI link in `metadata`) | no | no | yes (article URL) | no |
| Notes/description | yes (`note`) | yes (`notes`) | yes (`body`) | yes (`notes`) | yes (`body`) | yes (`notes`) | yes (description; full text fetched on demand) | yes (list item text is the title) |
| Parent/sub-item relationships | yes (nested tasks; `sub_items`, `sub_item_count`) | yes (subtasks; `sub_items`, `sub_item_count`) | no (sub-issues not read) | yes (parent task id in `metadata`) | no (app supports them; AppleScript does not) | no | no | yes (`child_list_items`; `sub_items`, list path in `metadata`) |
| Source activity timestamps | modification date only | modification date only | modification date; `comments_count` in `metadata` | modification date only | modification date only | `time_spent`/`time_remaining` in `metadata`; scheduled instances not published | `progress` (0-1) and `progress_timestamp` | note update time only |

## Notes policy

Every "Notes/description" row above describes what the source *exposes*, not
what the snapshot publishes. Raw note bodies, article text, and other
sensitive payloads are deliberately kept out of normalized snapshots: the
publication contract (#215, `docs/rdr-215-taskbridge-observation-publication-contract.md`)
requires note export to be opt-in per source through TaskBridge configuration,
and that setting does not exist yet. When it lands it will surface as
`notes_preview`, never as full `notes`.

## Per-source details

### OmniFocus

- Read over AppleScript (macOS only). Creation, modification, completion,
  defer, and due dates are all available; `estimated_minutes` and the flag
  are extracted.
- Tag-derived due dates (weekday/month/relative tags) are applied when the
  task has no explicit due date.
- The AppleScript `dropped`/`effectively_dropped` properties exist but are
  not read, so the snapshot status is only ever `open`/`completed`.
- No adapter-specific `metadata` is emitted; all read fields fit the common
  schema.

### Asana

- `created_at` is requested alongside `modified_at` (and in partial,
  date-only reads) so `source_created_at` is always populated.
- Tag names, assignee name, workspace gid/name, and the matched project and
  section gids are published in `metadata`; section names are also folded
  into `tags`.
- `start_on`/`start_at` are premium fields and may be absent on free
  workspaces.

### GitHub

- Issues and PRs arrive from the same endpoint. `number`, the PR flag, PR
  draft state, `repository` (`owner/name`), `author`, `assignees`,
  `milestone` title, and `comments_count` are published in `metadata`.
- `closed_at` maps to the snapshot's `completed_at`; a closed issue's
  `state_reason` (e.g. `not_planned`) is not currently read.

### Google Tasks

- The API exposes no creation timestamp; `updated` is the modification
  timestamp and `completed` is the completion timestamp (now mapped to
  `completed_at`).
- The containing task list is known from the service configuration; its
  title and id are published in `metadata` as `list`/`list_id`, along with
  the read-only `parent` task id and the web UI deep link.
- `deleted`/`hidden` flags exist on the payload but are not published
  (TaskBridge does not yet model deletion; see #214).

### Reminders

- Read over AppleScript. `creation_date` and `modification_date` are
  extracted; completion lands in `completed_on`.
- The AppleScript priority integer (0/1/5/9) is mapped to
  `none`/`low`/`medium`/`high` for the snapshot's `priority`; the raw value
  is kept in `metadata` as `priority_value`. Values outside the documented
  enumeration publish no label rather than a guess.
- Reminders exposes both an all-day and a timed due date; only the all-day
  value is currently mapped (to `due_at`). `remind_me_date` (the
  notification time) maps to `start_date`.
- Sub-reminders and tags are supported by the app but not accessible through
  the AppleScript dictionary TaskBridge uses.

### Reclaim

- Scheduling facts already visible in the payload are published in
  `metadata`: `status` (Reclaim's own `SCHEDULED`/`IN_PROGRESS`/`COMPLETE`
  value, distinct from the snapshot's open/completed/dropped status),
  `event_sub_type`, `at_risk`, and the 15-minute chunk accounting
  (`time_required`, `time_spent`, `time_remaining`, `minimum_chunk_size`,
  `maximum_chunk_size`, `always_private`).
- Scheduled instance windows (`instances`) are not published; they are
  per-event facts, not task state.

### Instapaper

- `folder` (unread vs archive) drives completion; `progress` (0-1) and
  `starred` are published in `metadata`; `progress_timestamp` is the
  modification timestamp.
- `estimated_minutes` is a computed read time (words + image heuristic) and
  is only present after the full article text has been fetched.

### Google Keep

- Keep list items have no stable API ID; TaskBridge embeds one invisibly in
  the item text, and `metadata.stable_external_id_embedded` records whether
  it was found.
- The containing note's id (`note_id`) and the item's position in the nested
  list structure (`list_path`) are published in `metadata`; note
  `update_time` is the modification timestamp. The API exposes no creation
  timestamp and no URL scheme for deep links.
