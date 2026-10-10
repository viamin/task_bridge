# Backfilling the TaskBridge Web outbox baseline

Covers issue #222 (parent #214). The backfill turns existing local
TaskBridge data (`sync_items`, `sync_collections`) into the baseline
current state TaskBridge Web starts from, so only later diffs count as
change history. It writes only local outbox rows — it never mutates
external source systems.

Reference: `docs/rdr-215-taskbridge-observation-publication-contract.md`
("Migration and Backfill Implications").

## What the backfill writes

| Row kind     | What it emits                                                                                                                              |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `item`       | One current-state snapshot per existing sync item, marked `provenance.detected_by: "backfill"` with a `backfilled_at` timestamp.            |
| `mapping`    | One membership row per `SyncCollection` member — but only for `confirmed` (sync-id / created-by-sync) and `inferred` (title-derived) confidence. |
| `observation` | Nothing. Baseline snapshots are not historical change events, so no `snapshot_seen` rows are fabricated.                                  |
| `sync_run`   | Nothing. `sync_service_states` has no reliable per-run start/end timestamps; live sync runs publish these going forward.                  |

Low-confidence (`low` → `tentative`) memberships are withheld from
publication. They stay identifiable in the dry-run summary's counts by
confidence for later manual cleanup or Web-side review. This resolves the
RDR #215 open question in favor of the RDR's stated default.

Single-instance services (OmniFocus, Reminders, …) publish under the
permanent `service_instance` token `<service_type>:default` (for example
`omnifocus:default`), matching the RDR's identity model. Because that
value is embedded in idempotency keys it can never change; the live
pipeline resolves identities through the same
`Outbox::SourceIdentity` default.

## Running it

Run the preview first, then the real backfill, then enable publication:

```bash
# 1. Preview: summarize what would be written, write nothing
rake task_bridge:outbox:backfill_baseline DRY_RUN=1

# 2. Backfill (also runs the idempotent provenance backfill first:
#    task_bridge:backfill_sync_provenance)
rake task_bridge:outbox:backfill_baseline

# 3. Optional: inspect the exact HTTP batches that would be sent
rake task_bridge:outbox:publish_dry_run

# 4. Enable task_bridge.web in config/settings.yml (or Chamber env vars),
#    then publish
rake task_bridge:outbox:publish
```

Example dry-run output:

```
Backfill baseline (dry run): items 412 enqueued (asana: 118, github: 96, google_tasks: 71, omnifocus: 127), 2 skipped, 0 dropped; mappings 388 enqueued, 23 withheld (tentative: 23), 0 skipped, 0 dropped
```

- **items by service** — baseline snapshots that would be enqueued per service.
- **mappings by confidence** — `confirmed` and `inferred` rows are enqueued; `tentative` rows are withheld and only counted here.
- **skipped** — records that cannot be published: items without an `external_id`, and collection members or collections without usable identity/provenance.
- **dropped** — rows whose isolated outbox write failed; a rerun re-detects them.

## Idempotency and safety

- Every row's idempotency key is derived from stable observation
  timestamps (each item's `last_observed_at`, each collection's
  `mapping_last_observed_at`), so rerunning the backfill leaves
  already-written rows untouched. Run it as many times as you like.
- The backfill reads local tables only. It never calls a provider API
  and never mutates external source systems.
- Existing rows keep their payloads immutable across reruns
  (`OutboxEntry` marks `payload` read-only), satisfying the RDR #215
  duplicate-key rules.
- A live sync that later observes the same item produces new
  observation/snapshot facts with new keys; the backfill never collides
  with or suppresses them.

## Where the code lives

- `app/services/sync_backfill/outbox_baseline.rb` — orchestrator.
- `app/services/sync_backfill/outbox_baseline/summary.rb` — counts by service and confidence.
- `app/services/sync_backfill/source_provenance.rb` — provenance backfill (identity fields, mapping evidence).
- `lib/tasks/outbox.rake` — `task_bridge:outbox:backfill_baseline`.
