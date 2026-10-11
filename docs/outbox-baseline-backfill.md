# Outbox Baseline Backfill (#222)

- Status: Implemented
- Issue: #222
- Parent: #214
- Contract: [RDR 215](rdr-215-taskbridge-observation-publication-contract.md)

## What the backfill does

Existing `sync_items` and `sync_collections` represent real synchronized
work. The baseline backfill seeds the local outbox so TaskBridge Web can
start from the known current state and only treat later diffs as change
history. It is a pair of rake tasks built on
`SyncBackfill::BaselineOutbox`:

- One `item` snapshot row per persisted sync item, carrying the item's
  normalized snapshot, `provenance.detected_by: "backfill"`, and a
  `provenance.backfilled_at` timestamp. Baseline rows describe current
  state — no `snapshot_seen` observation rows and no `sync_run` rows are
  fabricated (`sync_service_states` has no reliable per-run start/end
  timestamps; normal sync runs publish those going forward).
- One `mapping` row per `SyncCollection` membership whose mapping
  confidence is `high` or `medium`, published as `confirmed` and
  `inferred` respectively. `low`-confidence (unevidenced) memberships are
  withheld from publication and reported only in the summary.
- Items that are still missing identity/provenance fields are first
  repaired by the #216/#217 provenance backfill
  (`SyncBackfill::SourceProvenance`), which `BaselineOutbox` runs
  automatically.
- Items the live observation pipeline (#219) has never observed also get
  their `last_snapshot` diff baseline seeded, so the next live refresh of
  an unchanged item publishes nothing instead of repeating the baseline as
  a `snapshot_seen` observation.

The backfill reads only local database state. It never contacts or mutates
external source systems, and it never publishes anything by itself —
publication is the outbox publisher's job (#221).

## How to run it

Run the dry run first; it prints the counts a real run would produce
(items by service, mappings by confidence, withheld low-confidence
memberships with their collection IDs and titles, and skipped/incomplete
records with reasons) without persisting anything:

```bash
bin/rails task_bridge:outbox:backfill_dry_run
```

Then run the real backfill:

```bash
bin/rails task_bridge:outbox:backfill
```

Example dry-run output:

```
Baseline outbox backfill (dry run):
  items: would enqueue 5 (Asana:work: 1, Github: 1, GoogleTasks: 1, Omnifocus: 2), skipped 1 (missing_external_id: 1)
  mappings: would enqueue 4 (high: 2, medium: 2)
  mappings withheld from publication: 2 (low: 2) (#12 Buy milk (1 members), #14 Untitled (1 members))
```

Both tasks are safe to run repeatedly:

- Item and mapping rows use deterministic idempotency keys derived from
  each record's own observation timestamps, so reruns dedupe against
  already-enqueued rows instead of duplicating them.
- The provenance backfill only stamps records that are still missing
  provenance, so reruns leave observation timestamps untouched.

Run the backfill **before** enabling publication to TaskBridge Web
(`task_bridge.web.enabled` in `config/settings.yml`). The full sequence:

```bash
bin/rails task_bridge:outbox:backfill_dry_run  # preview counts, nothing written
bin/rails task_bridge:outbox:backfill          # seed the outbox
bin/rails task_bridge:outbox:publish_dry_run   # optional: inspect the exact batches (NDJSON)
# enable task_bridge.web in config/settings.yml, then:
bin/rails task_bridge:outbox:publish
```

Once publication is enabled, the outbox publisher delivers the baseline rows
in the next sync run or standalone `task_bridge:outbox:publish` run;
TaskBridge Web treats them as current state (upsert), not as historical
change events.

## Low-confidence mappings

Withholding `low`/`tentative` mappings matches the #222 clarification and
resolves RDR 215's open question in favor of the RDR's stated default:
backfill publishes only `confirmed` (ID-derived, `source_sync_id` /
`created_by_sync`) and `inferred` (title-derived, `title_fallback`)
memberships. Withheld memberships stay identifiable through the dry-run
summary, which lists them by collection ID, title, and member count for
manual cleanup or Web-side review.

Whether low-confidence memberships should eventually be published remains
an explicit product decision point: if the product owner later decides to
publish them, they can be re-enqueued by lowering the collection's
confidence threshold handling in `SyncBackfill::BaselineOutbox` — reruns
are safe, so previously withheld rows can be added at any time.

## Identity notes

- Services configured without an instance suffix (OmniFocus, Reminders,
  GitHub, Google Tasks, ...) publish with the permanent `:default`
  instance suffix (for example `omnifocus:default`), matching
  `Outbox::SourceIdentity::DEFAULT_INSTANCE`. The suffix is embedded in
  idempotency keys and item keys, so it can never change for a deployment.
- Extra payload fields such as `provenance.backfilled_at` are safe because
  version 1 consumers must ignore unknown fields (RDR 215 versioning
  rules).
