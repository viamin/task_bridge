# Backfilling the Outbox Baseline for TaskBridge Web

- Issue: #222
- Parent: #214
- Contract: [RDR 215](rdr-215-taskbridge-observation-publication-contract.md)

Existing `sync_items` and `sync_collections` represent real synchronized
work. Before enabling publication to TaskBridge Web, that data must be
seeded into the local outbox as **baseline current state**, so TaskBridge
Web starts from a known state and only treats later diffs as change
history.

## What the backfill writes

One run of `SyncBackfill::BaselineOutbox` (via the rake tasks below):

1. **Provenance backfill first** — `SyncBackfill::SourceProvenance.run!`
   rebuilds the identity/provenance columns on `sync_items` (STI type,
   `external_id`, `url`, `last_modified`, parsed notes, service instance
   names) and the mapping metadata on `sync_collections` where they are
   still missing. This step is the same one exposed by
   `rake task_bridge:backfill_sync_provenance` and is idempotent.
2. **One `item` row per existing `sync_items` row** carrying the same
   normalized snapshot the live pipeline publishes
   (`Base::SnapshotSerializer.published`), marked as a backfilled
   baseline — not as a historical change event — through payload metadata:

   ```json
   "provenance": {
     "detected_by": "backfill",
     "baseline": true,
     "backfilled_at": "2026-10-10T12:00:00.000000Z"
   }
   ```

   Extra payload fields are safe because version 1 consumers must ignore
   unknown fields.
3. **One `mapping` row per existing `SyncCollection` membership**, using
   the live `Outbox::MappingEmitter`, with internal confidences mapped to
   the contract vocabulary: `high` → `confirmed`, `medium` → `inferred`,
   `low` → `tentative`.
4. **No `observation` and no `sync_run` rows.** Baseline rows must not
   pretend to be historical change events (`snapshot_seen`/`source_changed`
   observations belong to the live pipeline), and `sync_service_states`
   has no reliable per-run `started_at`/`finished_at`, so backfilled
   sync-run summaries would violate the RDR's timestamp requirement.

### Withheld low-confidence mappings

Memberships held at `mapping_confidence: low` (contract value
`tentative`) are **not enqueued**. This resolves RDR 215's open question
in favor of the safer default: only `confirmed` and `inferred` mappings
are published during backfill. Withheld memberships stay identifiable for
manual cleanup or Web-side review through the dry-run summary's
`withheld by confidence` counts. Once a mapping's evidence upgrades
(for example, a later sync writes matching sync-id notes), the regular
sync flow publishes it.

### Service instance identity

Every row identifies its source through `Outbox::SourceIdentity`.
Services configured without an instance suffix (OmniFocus, Reminders,
Google Tasks, …) get the permanent default token `default`, producing
`service_instance` values such as `omnifocus:default` — matching the
RDR's `asana:workspace-12345:default` example shape. The token is
embedded in idempotency keys, so it can never change once shipped, and
the live pipeline uses the same builder so backfilled and live rows share
identities.

## Running the backfill

Run the dry run first and review its summary — counts by service, by
confidence, and skipped/incomplete records:

```bash
bundle exec rake task_bridge:outbox:backfill_baseline_dry_run
```

Then perform the real backfill (nothing is sent to TaskBridge Web yet;
rows only land in the local outbox as `pending`):

```bash
bundle exec rake task_bridge:outbox:backfill_baseline
```

Example output:

```
Baseline outbox backfill
Items: 412 enqueued, 0 already present, 3 skipped (no external id), 0 errors
  items by service: asana=120, github=64, google_tasks=95, omnifocus=133
Mappings: 190 enqueued, 0 already present, 37 withheld (low confidence), 5 skipped members, 0 errors
  mappings by confidence: confirmed=142, inferred=48
  withheld by confidence: low=37
```

After the backfill, enable publication (`task_bridge.web.enabled` in
`config/settings.yml` or the `TASK_BRIDGE_WEB_*` environment variables,
see `.env.example`); the next `rake task_bridge:outbox:publish` (or sync
run) delivers the baseline rows to TaskBridge Web.

## Safety properties

- **Idempotent.** Every row's idempotency key is derived from stable
  per-row timestamps (`last_observed_at` for items,
  `mapping_last_observed_at` for mappings), so reruns reuse the existing
  outbox rows instead of duplicating them; a rerun reports them as
  `already present`.
- **Read-only toward external systems.** The backfill only reads
  persisted rows — it never instantiates service clients, fetches, or
  patches OmniFocus, Asana, GitHub, Google Tasks, or any other source.
- **Non-fatal per row.** A record that cannot be serialized (or an outbox
  write that keeps failing) is reported to stderr and counted under
  `errors`; the remaining rows still backfill.
- **Dry run writes nothing.** The dry run executes the exact write path —
  including the provenance backfill — inside a transaction that always
  rolls back, so its counts match what a real run would do while the
  database stays untouched.
