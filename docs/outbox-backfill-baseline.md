# Outbox Baseline Backfill for TaskBridge Web

Issue #222 (parent #214). RDR: [rdr-215-taskbridge-observation-publication-contract.md](rdr-215-taskbridge-observation-publication-contract.md)

TaskBridge Web starts from **known current state** and only treats later diffs
as change history. Before enabling publication, existing `sync_items` and
`sync_collections` — real synchronized work — are seeded into the local outbox
as baseline rows.

## What the backfill does

`rake task_bridge:outbox:backfill` runs three idempotent steps:

1. **Identity/provenance backfill** (`SyncBackfill::SourceProvenance`, also
   available standalone as `rake task_bridge:backfill_sync_provenance`):
   fills `source_service_name`, `source_service_instance`,
   `source_service_type`, `source_external_id`, `source_url`,
   `source_updated_at`, `first_observed_at`/`last_observed_at` from each
   item's STI type, `external_id`, `url`, `last_modified`, parsed notes, and
   service instance names where available. `SyncCollection` mapping metadata
   (`mapping_method`/`mapping_confidence`/`mapping_metadata`) is inferred from
   member evidence, keeping title-derived (`medium`) mappings separate from
   ID-derived (`high`) ones.
2. **Baseline item snapshots**: one `item` outbox row per existing
   `sync_items` row, built from the shared `normalized_snapshot` so it cannot
   drift from live observation payloads. Rows are marked as baseline rather
   than historical change events: `provenance.detected_by: "backfill"` plus a
   `backfilled_at` timestamp. Each item's `last_snapshot` diff baseline
   (#219) is seeded in the same shape, so the first live refresh after the
   backfill publishes only real changes instead of rediscovering every item.
3. **Baseline mapping rows**: one `mapping` row per existing
   `SyncCollection` membership, reusing `Outbox::MappingEmitter`.

The backfill writes **local rows only** — it never contacts external source
systems.

### What the backfill deliberately does not emit

- **No `snapshot_seen` observation rows** (#222 clarified decision): the
  baseline is the `item` snapshot itself, marked with
  `provenance.detected_by: "backfill"` and `backfilled_at`. Extra payload
  fields are safe because v1 consumers must ignore unknown fields.
- **No `sync_run` rows** (#222 clarified decision): `sync_service_states`
  has no reliable per-run start/end timestamps, and the RDR only allows
  backfilled sync-run summaries where reliable historical timestamps exist.
  Live sync runs publish them going forward.
- **No deletion tombstones**: the RDR only allows tombstones where deletion
  can be stated confidently, which existing rows cannot express.

## Low-confidence mapping policy

Resolved per RDR #215's stated default (#222 clarified decision, recorded in
the RDR's Open Questions section):

| Internal `mapping_confidence` | Contract `mapping_confidence` | Backfill behavior |
| ----------------------------- | ----------------------------- | ----------------- |
| `high` (ID-derived, `created_by_sync`) | `confirmed` | published |
| `medium` (title-derived)      | `inferred`                    | published |
| `low` (no evidence)           | `tentative`                   | **withheld** |

Unknown/unprovenanced collections are also withheld. Withheld memberships are
never published in any form — member item snapshots omit their
`sync_collection` block — and remain identifiable through the dry-run
summary's counts by confidence (`tentative` bucket) for later manual cleanup
or Web-side review once the mapping is upgraded.

## Idempotency and rerun safety

- Item and mapping rows carry deterministic idempotency keys
  (`tb:v1:item:<service_instance>:<external_id>:snapshot:<observed_at>`,
  `tb:v1:map:sync_collection:<id>:membership:<service_instance>:<external_id>:<observed_at>`)
  built from stable observed timestamps (`last_observed_at`,
  `mapping_last_observed_at`), so an identical rerun re-derives the same keys.
- Identities that already have an outbox row of that kind are skipped, so a
  rerun — including after live syncs advanced the observed timestamps —
  enqueues nothing new.
- Mapping writes that hit a transient database failure are dropped with a
  warning (isolated per member by `Outbox::IsolatedWrite`); the next rerun
  re-enqueues exactly those memberships because they never landed in the
  outbox.
- `SyncBackfill::SourceProvenance` only fills blank provenance columns, so it
  is safe to rerun as well.

## Service instance identity

Every published row's `source.service_instance` ends in a fixed `:default`
token (`omnifocus:default`, `asana:work:default`, `github:repo-1:default`),
matching the RDR's `asana:workspace-12345:default` example. This default is
**permanent**: it is embedded in idempotency keys, so changing it would fork
the identity of every published row. The live pipeline resolves the same
value through `Outbox::SourceIdentity`, so backfilled and live rows share
identities.

## How to run the backfill

Run the dry run first — it writes nothing (not even provenance columns) and
summarizes counts by service, mapping confidence, and skipped/incomplete
records (items or memberships lacking an `external_id`):

```console
$ rake task_bridge:outbox:backfill_dry_run
TaskBridge outbox backfill (dry run — nothing was written)
Item snapshots by service:
  asana: 4 total, 4 would enqueue, 0 already in outbox, 0 incomplete (skipped)
  github: 3 total, 3 would enqueue, 0 already in outbox, 0 incomplete (skipped)
  ...
Mapping memberships by confidence:
  confirmed: 6 memberships, 6 would enqueue, 0 already in outbox, 0 withheld, 0 incomplete (skipped)
  inferred: 2 memberships, 2 would enqueue, 0 already in outbox, 0 withheld, 0 incomplete (skipped)
  tentative: 3 memberships, 0 would enqueue, 0 already in outbox, 3 withheld, 0 incomplete (skipped)
  ...
Incomplete items lack an external_id and were skipped; first 10 ids: ...
```

Then apply it — safe to rerun any number of times:

```console
$ rake task_bridge:outbox:backfill
```

Preview the exact batches that would be sent before connecting TaskBridge Web:

```console
$ rake task_bridge:outbox:publish_dry_run
```

Finally, enable publication (`task_bridge.web.enabled: true` plus `base_url`
and `api_key` in `config/settings.yml` or the `TASK_BRIDGE_WEB_*` environment
variables) and publish:

```console
$ rake task_bridge:outbox:publish
```

Order matters operationally (backfill before enabling publication) so
TaskBridge Web's first contact with this deployment is the full baseline, but
the backfill remains safe to rerun after publication is live.
