# Outbox Backfill Runbook (#222)

Existing `sync_items` and `sync_collections` represent real synchronized
work. The backfill seeds the local outbox with the baseline rows TaskBridge
Web needs to start from known current state, so only later diffs become
change history (RDR #215, "Migration and Backfill Implications").

## What the backfill writes

- One current-state `item` snapshot row per existing `sync_items` row
  (including its STI-derived source identity, parsed notes digest, and
  normalized metadata). Baseline rows are marked
  `provenance.detected_by: "backfill"` with a `backfilled_at` timestamp so
  they are never mistaken for historical change events.
- One `mapping` row per `SyncCollection` membership whose mapping confidence
  is publishable: `high` → `confirmed` and `medium` (title-derived) →
  `inferred`. Low-confidence or unlabelled memberships are **withheld**
  from publication and listed by the dry run instead (RDR #215's resolved
  low-confidence backfill question).
- Each backfilled item's stored diff baseline (`last_snapshot`) is seeded
  when blank, so the next live refresh publishes only later diffs instead
  of re-discovering every item.

The backfill deliberately writes **no** `snapshot_seen` observation rows
and **no** `sync_run` rows — live sync runs publish those going forward —
and it never contacts external source systems; its only writes are outbox
rows and the diff baseline seed.

## Running it

Run the tasks in this order, before enabling publication to TaskBridge Web
(`task_bridge.web.enabled` in `config/settings.yml`, default `false`):

```bash
# 1. Backfill identity/provenance fields and mapping metadata (#218) so
#    items carry source identity and collections carry mapping confidence.
bundle exec rake task_bridge:backfill_sync_provenance

# 2. Preview: counts by service and confidence, skipped/incomplete
#    records, and the withheld low-confidence membership list.
#    Writes nothing.
bundle exec rake task_bridge:outbox:backfill_dry_run

# 3. Seed the outbox baseline rows.
bundle exec rake task_bridge:outbox:backfill

# 4. Optionally preview the exact publication batches (NDJSON on stdout,
#    nothing sent), then enable task_bridge.web and let the publisher run.
bundle exec rake task_bridge:outbox:publish_dry_run
```

Dry-run output looks like:

```
Outbox backfill (dry run: nothing was written): 42 item snapshots enqueued, 17 mapping rows enqueued, 3 memberships withheld (low/unknown confidence), 1 items skipped (incomplete)
item snapshots by service:
  asana: 12 enqueued, 0 skipped
  omnifocus: 18 enqueued, 1 skipped
mapping memberships by confidence:
  high: 10 enqueued, 0 withheld, 0 skipped
  medium: 7 enqueued, 0 withheld, 0 skipped
  low: 0 enqueued, 3 withheld, 0 skipped
withheld memberships held back from publication (review or confirm manually):
  SyncCollection #84 "Release checklist" member omnifocus:default:of-456 (confidence: low, method: manual_backfill)
```

## Safety and idempotency

- **Rerunnable**: rows carry deterministic idempotency keys (derived from
  source identity plus the item's last-observed timestamp), and reruns skip
  source identities that already have a baseline row, so running the
  backfill multiple times never duplicates rows — even after live syncs
  bumped timestamps in between.
- **No external mutation**: the backfill reads local tables only; provider
  APIs and AppleScript surfaces are never contacted.
- **Single-instance services** publish as `<service_type>:default` (for
  example `omnifocus:default`) — a permanent default embedded in the
  idempotency keys, shared with the live pipeline so backfilled and live
  rows identify the same source.

## Reviewing withheld mappings

Withheld memberships never reach TaskBridge Web from the backfill. Review
them from the dry-run list, then either confirm the mapping (for example,
by letting a sync upgrade it to a sync-id match) or correct it locally; a
later sync run publishes the upgraded membership as a regular `mapping`
row. Raising a collection's confidence without real evidence is not
recommended — the withholding exists precisely because title-derived or
manual pairings may be wrong.
