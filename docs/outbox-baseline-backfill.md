# Outbox Baseline Backfill (#222)

How to seed TaskBridge Web's initial view of existing TaskBridge data
before enabling publication. See
[docs/rdr-215-taskbridge-observation-publication-contract.md](rdr-215-taskbridge-observation-publication-contract.md)
for the publication contract this feeds.

## What the backfill writes

`rake task_bridge:outbox:backfill_baseline` is a strictly local,
idempotent task over existing `sync_items` and `sync_collections`:

1. **Provenance first.** It runs the existing provenance backfill
   (`task_bridge:backfill_sync_provenance`) so every item carries
   identity/provenance fields (STI type, `external_id`, `url`,
   `last_modified`, parsed sync notes, service instance names) and every
   collection carries mapping method/confidence metadata. That step
   already separates ID-derived mappings (`source_sync_id`, high) from
   title-derived ones (`title_fallback`, medium) and unevidenced ones
   (`manual_backfill`, low).
2. **One `item` snapshot row per existing sync item.** The row is a
   current-state snapshot marked as baseline — not a historical change
   event: the payload carries `provenance.detected_by: "backfill"` plus a
   `backfilled_at` timestamp, and the deterministic idempotency key is
   derived from stable data (`last_observed_at`), so reruns never
   duplicate rows. When available, the stored live `last_snapshot` is
   reused because it was serialized with full external context; otherwise
   the snapshot is rebuilt from persisted state.
3. **One `mapping` row per existing `SyncCollection` membership** — but
   only for mappings at `confirmed` (internal `high`) or `inferred`
   (internal `medium`) confidence. Low-confidence (`tentative`)
   memberships are **withheld** from publication; they remain identifiable
   in the dry-run summary (see the decision point below).
4. **No `observation` rows and no `sync_run` rows.** Baseline data is not
   change history, and `sync_service_states` has no reliable per-run
   start/end timestamps (RDR #215 requires reliable timestamps for
   backfilled sync-run summaries). Normal sync runs publish those record
   kinds going forward.
5. **Diff baselines are stamped.** Each item's `last_snapshot` is set to
   the published baseline, so the live observation pipeline (#219)
   treats this state as known current state and only later diffs arrive
   as `source_changed` history.

The backfill never contacts external source systems; it reads and writes
only the local database.

## Decision point: low-confidence mappings (resolved)

The issue called out an explicit decision on how to treat title-derived
or unevidenced existing mappings. The resolved policy (RDR #215's stated
default, confirmed under #222):

- Internal confidence translates to the contract as `high -> confirmed`,
  `medium -> inferred`, `low -> tentative`.
- Backfill publishes only `confirmed` and `inferred` mapping rows and
  withholds `tentative` ones.
- Withheld memberships stay reviewable through the dry-run summary
  (collection id, title, confidence, member count). If the product
  decision changes, `Outbox::MappingEmitter.publishable_confidence?`
  is the single gate to update.

The `:default` service instance token (for example `omnifocus:default`)
is permanent: it is embedded in idempotency keys, and the live pipeline
resolves the same token through `Outbox::SourceIdentity`, so backfilled
and live rows share identities.

## How to run it

Run the dry run first — it writes nothing (no outbox rows, no provenance
changes, no `last_snapshot` stamps) and summarizes what the real run
would enqueue, by service, by mapping confidence, and any
skipped/incomplete records:

```bash
bundle exec rake task_bridge:outbox:backfill_baseline_dry_run
```

Example output:

```
Baseline backfill dry run: would enqueue 412 item snapshot row(s) (asana=98, github=133, google_tasks=57, omnifocus=124)
would enqueue 180 mapping row(s) (confirmed=142, inferred=38); withheld 26 low-confidence membership(s) across 11 collection(s)
  withheld collection 84 "Review someday" (tentative, 2 member(s))
Skipped/incomplete: 3 item(s) without external_id (github=3), 1 mapping member(s) without external_id, 0 collection(s) without mapping confidence
Nothing was written; run task_bridge:outbox:backfill_baseline to enqueue these rows
```

Then run the real backfill (safe to repeat; reruns create no new rows):

```bash
bundle exec rake task_bridge:outbox:backfill_baseline
```

Preview the exact batches publication would send, still without sending
anything (renders NDJSON to stdout):

```bash
bundle exec rake task_bridge:outbox:publish_dry_run
```

Only after reviewing that output, enable publication
(`task_bridge.web.enabled` in config/settings.yml or the
`TASK_BRIDGE_WEB_*` environment variables, see .env.example) and let the
hourly sync / `task_bridge:outbox:publish` deliver the baseline. Rows
stay pending in the outbox until TaskBridge Web accepts them, so the
backfill can run days before publication is switched on.
