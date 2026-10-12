# Backfilling existing sync data for TaskBridge Web (#222)

This describes how to seed the outbox with a safe baseline before enabling
publication to TaskBridge Web (RDR
[#215](rdr-215-taskbridge-observation-publication-contract.md)). Run every
step below with `task_bridge.web.enabled: false` (the default in
`config/settings.yml`) — the backfill only writes local `outbox_entries`
rows; it never calls TaskBridge Web and never mutates external source
systems. Nothing is actually published until you flip `enabled: true` and
run `rake task_bridge:outbox:publish`.

## 1. Backfill identity and mapping provenance

```bash
bundle exec rake task_bridge:backfill_sync_provenance
```

Populates `sync_items.source_service_name`/`source_external_id`/etc. and
`sync_collections.mapping_method`/`mapping_confidence` for existing rows
(`SyncBackfill::SourceProvenance`). Safe to rerun: it skips any item or
collection that already carries provenance.

## 2. Preview the baseline snapshot and mapping rows (dry run)

```bash
bundle exec rake task_bridge:backfill_baseline_observations_dry_run
```

Prints counts without writing any outbox rows:

- **Item snapshots** — one baseline `item` row per existing `sync_items`
  row that has identity from step 1, broken down by service, plus how many
  were skipped because identity is still missing.
- **Mapping memberships** — one `mapping` row per `SyncCollection`
  membership eligible for publication, broken down by resolved confidence
  (`confirmed`/`inferred`/`tentative`, mapped from `high`/`medium`/`low`)
  and by service, plus how many were withheld or skipped.

Review the `withheld_low_confidence` count before continuing. Low-confidence
(`manual_backfill`/`title_fallback` without a matching sync-id note)
memberships are **not** enqueued — they stay visible only in this summary
so a human can confirm, upgrade, or discard them (`SyncCollection` rows with
`mapping_confidence: "low"`) before they ever reach TaskBridge Web. This
resolves RDR #215's open question in favor of its documented default:
withhold `tentative` mappings from backfill publication.

## 3. Write the baseline rows

```bash
bundle exec rake task_bridge:backfill_baseline_observations
```

Enqueues the same rows the dry run previewed
(`SyncBackfill::BaselineObservations`, backed by
`SyncBackfill::ItemSnapshots` and `SyncBackfill::MappingObservations`).
Idempotent: every row's idempotency key is deterministic, so rerunning
this task (e.g. after backfilling more provenance) only adds rows for
newly-eligible items/mappings and never duplicates existing ones.

Baseline item rows carry `provenance.detected_by: "backfill"` and a
`provenance.backfilled_at` timestamp so TaskBridge Web can distinguish a
backfilled starting point from a historical change event. No `sync_run`
rows are written by this backfill — `sync_service_states` has no reliable
per-run start/end timestamps, so sync-run summaries are left to normal sync
runs going forward.

## 4. Preview what would actually be sent

```bash
bundle exec rake task_bridge:outbox:publish_dry_run
```

Renders the pending batches (NDJSON on stdout) without sending them, so you
can confirm the payloads look right before any network call happens.

## 5. Enable publication

Once the dry runs look right, set `task_bridge.web.enabled: true` (and
`base_url`/`api_key`) in your deployment's configuration, then run:

```bash
bundle exec rake task_bridge:outbox:publish
```

or let the next `task_bridge:sync` run publish automatically.
