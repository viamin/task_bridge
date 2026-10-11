# Backfilling the TaskBridge Web baseline (#222)

Existing `sync_items` and `sync_collections` rows represent real synchronized
work that predates the observation publication pipeline (#219-#221). The
baseline backfill seeds the local outbox with rows describing that existing
data so TaskBridge Web can start from the known current state and only treat
later diffs as change history (RDR #215, "Migration and Backfill
Implications").

## What the backfill writes

One **item** snapshot row per known source item:

- the item's normalized current state (`title`, `status`, `is_deleted`,
  timestamps, tags, source identity) published under record kind `item`;
- marked as baseline in the payload — `provenance.detected_by: "backfill"`
  plus a `backfilled_at` timestamp — so it is never mistaken for a
  historical change event;
- keyed by the item's stable `last_observed_at`, so the same fact always
  maps to the same `idempotency_key`;
- the published snapshot is also stored as the item's local diff baseline
  (`last_snapshot`), so the next live sync only publishes actual changes
  instead of re-discovering every item.

One **mapping** row per `SyncCollection` membership whose mapping
TaskBridge holds at publishable confidence:

- `high` (ID-derived: `source_sync_id`, `created_by_sync`) publishes as
  `confirmed`;
- `medium` (title-derived: `title_fallback`) publishes as `inferred`;
- `low` (`manual_backfill`) memberships are **withheld** — no mapping row is
  enqueued and item snapshots omit their `sync_collection` block. They stay
  identifiable for manual cleanup or Web-side review through the dry-run
  summary's counts by confidence (`tentative`). This resolves RDR #215's
  open question in favor of the safer default.

The backfill writes **no** `snapshot_seen`/`source_changed` observation
rows, **no** `sync_run` summaries (normal sync runs publish those going
forward), and **no** deletion tombstones. Before generating rows it re-runs
the idempotent source-provenance backfill (#218,
`task_bridge:backfill_sync_provenance`) so identity fields
(`source_service_*`, `first_observed_at`/`last_observed_at`) and
`SyncCollection` mapping metadata exist.

## Safety properties

- **Idempotent**: run it as many times as you like. Item rows are skipped
  once the item has a diff baseline; mapping rows reuse their deterministic
  idempotency keys, so reruns re-find the same rows.
- **Local only**: it reads `sync_items`/`sync_collections` and writes
  `outbox_entries`. It never contacts an external source system.
- **Publication stays gated**: enqueued rows sit pending until TaskBridge
  Web publication is enabled and run. The backfill never sends anything.

## `service_instance` stability

Single-instance services (OmniFocus, Reminders, Google Tasks, GitHub)
publish under `<service_type>:default` (for example `omnifocus:default`);
instanced services keep their configured instance (`asana:work`). The
default is permanent — it is embedded in idempotency keys — and the live
pipeline uses the same rule, so backfilled and live rows share identities.

## Running the backfill

Run the backfill **before** enabling publication to TaskBridge Web, while
`task_bridge.web.enabled` is still `false`:

```bash
# 1. Preview: counts by service, confidence, and skipped records.
#    Writes nothing.
bin/rails task_bridge:outbox:backfill_baseline DRY_RUN=1

# 2. Backfill for real. Safe to re-run; review the summary it prints.
bin/rails task_bridge:outbox:backfill_baseline

# 3. Verify the pending rows (optional) — batches can be previewed as NDJSON:
bin/rails task_bridge:outbox:publish_dry_run | jq .

# 4. Only then enable publication (config/settings.yml or Chamber overrides):
#    task_bridge.web.enabled: true, base_url, api_key — then publish:
bin/rails task_bridge:outbox:publish
```

The next regular sync run also publishes pending rows at its end, so step 4
can be skipped if a sync is imminent.

Dry-run notes: a dry run writes nothing, so it skips the provenance
prerequisite and computes mapping confidence read-only instead; counts match
what the real run would produce. Run `task_bridge:backfill_sync_provenance`
first if you want the dry run to reflect a provenance backfill that has not
happened yet (the real run performs it automatically).
