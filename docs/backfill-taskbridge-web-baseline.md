# Backfilling the TaskBridge Web baseline

- Issue: #222
- Parent: #214
- Contract: [RDR 215](rdr-215-taskbridge-observation-publication-contract.md)

TaskBridge Web starts from a known current state: existing `sync_items` and
`sync_collections` represent real synchronized work, and the backfill publishes
them as **baseline** rows so only later diffs become change history. This guide
covers how to run the backfill **before enabling publication to TaskBridge Web**.

## What the backfill writes

| Row kind | Source | Notes |
|----------|--------|-------|
| `item` | one per existing `sync_items` row with an `external_id` | The item's normalized snapshot, marked as baseline in the payload: `provenance.detected_by: "backfill"` plus a `backfilled_at` timestamp. Extra fields beyond the contract minimum are safe: version 1 consumers ignore unknown fields. |
| `mapping` | one per `SyncCollection` membership | Published only for `high` (`confirmed`) and `medium` (`inferred`) mapping confidence, using the same payload shape as live mapping emission plus the baseline provenance markers. |
| `observation` | none | Baseline rows are current state, not historical change events. The backfill never emits observations; `snapshot_seen` observations begin with the live pipeline (#219-#221). |
| `sync_run` | none | `sync_service_states` has no reliable per-run start/end timestamps (RDR 215 requires them); live sync runs publish summaries going forward. |

Decisions recorded in #222 (resolving RDR 215's open question in favor of its
stated default):

- Low-confidence (`low`/`tentative`) and unknown-confidence memberships are
  **withheld** from publication. They stay identifiable through the dry-run
  summary's counts by confidence for later manual cleanup or Web-side review.
- Internal confidence maps to the contract enum as `high` → `confirmed`,
  `medium` → `inferred`, `low` → `tentative`.
- Services configured without an instance suffix (OmniFocus, Reminders, Google
  Tasks, ...) publish with the permanent default token
  `service_instance: "<service_type>:default"` (e.g. `omnifocus:default`). This
  token is embedded in idempotency keys and shared with the live pipeline, so
  backfilled and live rows agree on identity.

## Safety properties

- **Idempotent**: idempotency keys derive from each record's own stable
  timestamps, and reruns skip records that already have a baseline row — even
  after live sync traffic bumps those timestamps. Run it as many times as you
  like.
- **Local only**: the backfill reads existing sync data and writes local outbox
  rows. It never contacts or mutates external source systems.
- **Bounded claims**: item snapshots of withheld memberships omit the
  `sync_collection` block, so a withheld mapping asserts nothing.

## How to run

```bash
# 1. Preview: counts by service, by mapping confidence, and skipped/incomplete
#    records. Writes nothing (does not run the provenance backfill either).
bin/rails task_bridge:outbox:backfill_baseline_dry_run

# 2. Backfill: first re-runs the idempotent provenance backfill (#217) so
#    identity/mapping metadata is populated, then enqueues baseline rows and
#    prints the same summary.
bin/rails task_bridge:outbox:backfill_baseline

# 3. (Optional) Preview the exact publication batches without sending them.
bin/rails task_bridge:outbox:publish_dry_run

# 4. Enable publication (task_bridge.web.enabled plus base_url and api_key,
#    see .env.example); pending rows — backfilled and live alike — are then
#    delivered by task_bridge:outbox:publish or the next sync run.
```

Example dry-run output:

```
Baseline backfill dry run (nothing was enqueued)
Items: 214 total, 210 to enqueue, 0 already backfilled, 4 skipped
  omnifocus: 120 to enqueue, 3 skipped
  asana: 40 to enqueue
  github: 34 to enqueue
  google_tasks: 16 to enqueue, 1 skipped
  skipped reasons: 4 missing_external_id
Mappings: 96 memberships, 62 to enqueue, 0 already backfilled, 34 withheld, 0 skipped
  high confidence: 60 to enqueue
  medium confidence: 2 to enqueue
  low confidence: 32 withheld
  unknown confidence: 2 withheld
```

Records are counted as skipped when they cannot be identified (missing
`external_id`) or snapshotted (the reason is printed to stderr); skipped
memberships of withheld collections stay reviewable through the confidence
counts.

## Cleaning up low-confidence mappings later

Withheld memberships are not lost: the dry-run summary counts them, and the
underlying `SyncCollection` rows keep their `mapping_method`/`mapping_confidence`
provenance. To publish one, upgrade its evidence — typically by letting sync
link the representations through sync IDs (or manually adding the peer service's
`<service>_id:` note line) — then rerun the backfill: memberships whose
confidence rose to `medium`/`high` and do not yet have a baseline row are
enqueued then.

Note that a rerun will not re-publish a membership that already has a baseline
row; later confidence upgrades flow through the live pipeline's mapping
emission, which publishes new facts under new idempotency keys.
