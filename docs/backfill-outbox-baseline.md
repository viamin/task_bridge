# Backfilling the TaskBridge Web baseline (#222)

Existing `sync_items` and `sync_collections` represent real synchronized
work that predates the observation pipeline (#216-#221). The backfill
seeds the outbox with a **baseline of current state** so TaskBridge Web
starts from known data and only treats later diffs as change history
(RDR #215: `docs/rdr-215-taskbridge-observation-publication-contract.md`).

## What the backfill writes

| Row kind | Written per | Notes |
|---|---|---|
| `item` | One current-state snapshot per existing `Base::SyncItem` with an `external_id` | Marked as baseline in the payload: `provenance.detected_by: "backfill"` plus a `backfilled_at` timestamp |
| `mapping` | One row per existing `SyncCollection` membership whose collection has `high` or `medium` mapping confidence | `high` publishes as `confirmed`, `medium` (title-derived) as `inferred` |
| `observation` | Nothing | `snapshot_seen` discovery belongs to the live pipeline (#219) |
| `sync_run` | Nothing | `sync_service_states` has no reliable per-run start/end timestamps |

The backfill first runs the #218 provenance backfill
(`rake task_bridge:backfill_sync_provenance`) so every legacy row has
source identity, observation timestamps, and mapping confidence before
baseline rows are derived from it.

## Low-confidence mappings are withheld

Per the #222 clarification (resolving RDR #215's open question), the
backfill **does not publish `low`-confidence (`tentative`) memberships**.
They remain identifiable for manual cleanup or Web-side review through the
dry-run summary's counts by confidence. To promote a withheld collection,
either let sync re-evaluate it (e.g. add the missing sync ID notes so the
mapping upgrades to `high`) or merge the representations manually; the
next sync run then publishes the upgraded mapping through the live
pipeline.

How title-derived vs. low-confidence mappings should eventually be
treated remains an explicit product decision point; the current policy is
limited to backfill publication, and the live pipeline still emits
`tentative` rows it observes itself.

## How to run it

Run the dry run first. It is read-only (it also skips the provenance
backfill) and summarizes what the real run would enqueue:

```bash
bundle exec rake task_bridge:outbox:backfill_dry_run
```

```
Outbox backfill dry run (nothing was enqueued):
  items: 412 enqueued (0 already present), 3 skipped incomplete; by service: asana=190, github=44, google_tasks=61, omnifocus=117
  mappings: 596 enqueued (0 already present), 84 withheld low confidence, 5 skipped incomplete, 0 skipped unknown confidence; by confidence: high=488, low=84, medium=108
```

Review the `withheld low confidence` count and clean up those collections
if you want them published (see above). Then run the backfill:

```bash
bundle exec rake task_bridge:outbox:backfill
```

Preview the resulting batches without sending anything:

```bash
bundle exec rake task_bridge:outbox:publish_dry_run
```

Only then enable publication to TaskBridge Web (`task_bridge.web.enabled`
in `config/settings.yml`) and schedule
`bundle exec rake task_bridge:outbox:publish` alongside the regular sync.

## Safety properties

- **Idempotent**: every idempotency key is derived from a stable
  per-record timestamp (`last_observed_at` for items,
  `mapping_last_observed_at` for collections — both pinned by the
  provenance backfill), never the wall clock. Rerunning reproduces
  identical keys and payloads; rows the previous run enqueued are counted
  as `already present` instead of duplicated. Payloads stay
  byte-identical across reruns, honoring the RDR #215 rule that a
  resubmitted key must carry the same canonical payload.
- **Local only**: the backfill writes outbox rows and provenance columns;
  it never contacts external source systems.
- **Not change history**: baseline rows describe current state. Items
  still emit their first live `snapshot_seen` observation on the next
  sync because the backfill does not advance the diff baseline
  (`last_snapshot`).

## Identity stability

Items from single-instance services (OmniFocus, Google Tasks, Reminders,
…) have no `Asana:work`-style instance suffix, so their
`service_instance` falls back to `<service_type>:default` (for example
`omnifocus:default`), matching the RDR #215 identity examples. This
token is embedded in idempotency keys and can never change; the live
pipeline uses the same default so backfilled and live rows agree on item
identity.
