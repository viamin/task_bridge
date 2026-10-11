# Backfilling the outbox baseline for existing sync data

This describes how to seed the local outbox (RDR #215) with a safe baseline
from existing `sync_items` and `sync_collections` before TaskBridge Web
publication is enabled. See
`docs/rdr-215-taskbridge-observation-publication-contract.md` for the
publication contract and `SyncBackfill::OutboxBaseline` for the
implementation.

## What it does

- Writes one current-state `item` snapshot per existing `sync_items` row
  that has an external ID, marked `provenance.detected_by: "backfill"`
  (never as a live `snapshot_seen`/`source_changed` observation — a
  baseline is not a change event).
- Writes one `mapping` row per `sync_collections` membership held at
  `confirmed` (mapped from `high`) or `inferred` (mapped from `medium`)
  confidence.
- Withholds `low`-confidence (`tentative`) mappings from publication; they
  are counted in the summary so they stay identifiable for manual cleanup
  or Web-side review, per
  `docs/rdr-215-taskbridge-observation-publication-contract.md`'s stated
  default for this previously open question.
- Writes no `observation` or `sync_run` rows — `sync_service_states` has no
  reliable per-run timestamps, and normal sync runs become producers of
  those under #219-#221.
- Never mutates `sync_items`, `sync_collections`, or any external source
  system; it only reads them and enqueues outbox rows.

## Prerequisites

Run the identity/provenance backfill first so `source_service_name`,
`source_service_instance`, and `sync_collections` mapping metadata are
populated (#216-#218):

```bash
bundle exec rake task_bridge:backfill_sync_provenance
```

## Running the backfill

1. Preview counts without writing anything:

   ```bash
   bundle exec rake task_bridge:backfill_outbox_baseline_dry_run
   ```

   Review the printed summary: counts of item snapshots by service,
   mapping rows by confidence, withheld low-confidence mappings, and
   skipped/incomplete records (missing external IDs or mapping
   provenance). Re-run `task_bridge:backfill_sync_provenance` first if the
   skipped/incomplete counts are higher than expected.

2. Run the backfill for real. This only writes rows to the local
   `outbox_entries` table — it does not send anything anywhere:

   ```bash
   bundle exec rake task_bridge:backfill_outbox_baseline
   ```

   It is safe to run multiple times: `OutboxEntry.enqueue` dedupes on a
   deterministic idempotency key, and the backfill never changes the
   `last_observed_at`/`updated_at` timestamps those keys are derived from,
   so reruns find the existing rows instead of duplicating them.

3. Only once the dry-run and real-run summaries look right, enable
   publication in `config/settings.yml` (`task_bridge.web.enabled: true`,
   plus `base_url`/`api_key`) and run:

   ```bash
   bundle exec rake task_bridge:outbox:publish
   ```

   Publication stays off (`task_bridge.web.enabled: false`) until this
   step, so the backfill can be inspected and re-run freely beforehand.
