# Outbox Baseline Backfill (TaskBridge Web Seeding)

TaskBridge's observation pipeline publishes normalized task facts to
TaskBridge Web from a local outbox (see
[docs/rdr-215-taskbridge-observation-publication-contract.md](rdr-215-taskbridge-observation-publication-contract.md)).
Data that was already synchronized before that pipeline existed has no
observation history, so the backfill seeds the outbox with a **baseline
current state** for it (issue #222):

- one `item` snapshot per existing `sync_items` row;
- one `mapping` row per existing `SyncCollection` membership whose mapping
  confidence translates to `confirmed` or `inferred`.

The backfill is deliberately conservative about what it claims:

- Baseline rows are marked `provenance.detected_by: "backfill"` plus a
  `backfilled_at` timestamp, so TaskBridge Web never mistakes them for
  historical change events. No `snapshot_seen` observation rows and no
  `sync_run` summaries are produced (`sync_service_states` holds no
  reliable per-run start/end timestamps; live runs publish those going
  forward).
- Item snapshots only state facts persisted in local columns (title,
  status, timestamps, source identity). Tags, parent references, and
  provider metadata are not persisted per item, so they are omitted
  rather than guessed; the next live sync publishes them.
- Low-confidence (`tentative`) mappings are **withheld** from publication.
  This resolves RDR #215's open question: `high` maps to `confirmed`,
  `medium` maps to `inferred`, and `low`/`tentative` memberships stay
  local until they are upgraded by a later sync or cleaned up manually.
  They remain identifiable in the dry-run summary, which reports counts
  by confidence.
- The backfill never mutates external source systems and never writes
  `sync_items` or `sync_collections`; it only reads them and enqueues
  outbox rows.
- `service_instance` defaults to `<service_type>:default` for services
  configured without an instance suffix (e.g. `omnifocus:default`). This
  token is permanent — it is embedded in idempotency keys — and the live
  pipeline resolves the same default, so backfilled and live rows share
  identities.

## Idempotency

Every row uses the deterministic RDR #215 idempotency key derived from the
row's identity plus its stored `observed_at` (`last_observed_at` for
items, `mapping_last_observed_at` for collections), and `OutboxEntry`
deduplicates on that key. Re-running the backfill — even after a partial
failure or with a later `backfilled_at` — leaves previously enqueued rows
untouched. A row is only re-derived as a *new* fact when the underlying
item or collection has since been observed again, which is exactly the
live pipeline's semantics.

## Running the backfill

Run the provenance backfill first (it fills `sync_items` identity columns
and `SyncCollection` mapping metadata the baseline depends on), preview
what the baseline backfill would enqueue, then run it for real — all
before enabling publication to TaskBridge Web:

```bash
# 1. Backfill identity/provenance fields and mapping metadata (#218).
bin/rails task_bridge:backfill_sync_provenance

# 2. Preview baseline counts by service and confidence (enqueues nothing).
bin/rails task_bridge:outbox:backfill_baseline_dry_run

# 3. Seed the outbox with the baseline (safe to re-run).
bin/rails task_bridge:outbox:backfill_baseline

# 4. Optionally preview the exact batches that would be sent.
bin/rails task_bridge:outbox:publish_dry_run

# 5. Enable publication (task_bridge.web.enabled in config/settings.yml
#    or TASK_BRIDGE_WEB_ENABLED); the next sync run or
#    task_bridge:outbox:publish delivers the baseline.
```

The dry-run report looks like:

```
Outbox baseline backfill (dry run — nothing was enqueued)
Item snapshots (would be enqueued): 5 across 4 services
  omnifocus: 2
  asana: 1
  github: 1
  google_tasks: 1
Mapping memberships (would be enqueued): 3
  confirmed: 2
  inferred: 1
Withheld mappings (not published; review locally): 4
  tentative: 4
Skipped/incomplete records: 2
  missing_mapping_metadata:
    collections: 1
  missing_external_id:
    github: 1
```

`missing_mapping_metadata` collections are those the provenance backfill
has not classified yet — re-run `task_bridge:backfill_sync_provenance` and
the baseline backfill to pick them up. Withheld `tentative` memberships
are reviewable locally (their `SyncCollection` rows carry
`mapping_method`/`mapping_confidence`); they publish automatically once a
later sync upgrades their evidence to `confirmed` or `inferred`.
