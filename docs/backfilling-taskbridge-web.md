# Backfilling TaskBridge Web (#222)

Existing `sync_items` and `sync_collections` rows represent real,
already-synchronized work. Before TaskBridge Web starts receiving live
observations (#219-#221), this backfill gives it a safe baseline: a current-
state snapshot for every existing item, and a mapping row for every
cross-system membership TaskBridge already holds with reasonable
confidence. See `docs/rdr-215-taskbridge-observation-publication-contract.md`
("Migration and Backfill Implications") for the contract this follows.

The backfill only reads and writes TaskBridge's own database
(`sync_items`, `sync_collections`, `outbox_entries`). It never calls a
source provider API and never mutates Asana, GitHub, OmniFocus, or any
other external system.

## Run order

Run these in order, before turning on `task_bridge.web.enabled`:

1. **`bin/rails task_bridge:backfill_sync_provenance`**

   Fills in each `sync_items` row's identity/provenance columns
   (`source_service_name`, `source_service_instance`, `source_external_id`,
   `source_url`, `source_updated_at`, `first_observed_at`,
   `last_observed_at`) from already-known local data -- STI `type`, the
   existing `external_id`/`url`/`last_modified`, and sync IDs parsed from
   notes -- and backfills each `sync_collections` row's mapping provenance
   (`mapping_method`, `mapping_confidence`, `mapping_metadata`) by replaying
   `Base::SyncItem#mapping_provenance_with` across each collection's
   members. Only touches rows that are still blank, so it is safe to run
   repeatedly and run before every later step.

2. **`bin/rails task_bridge:backfill_outbox_baseline_dry_run`**

   Prints a JSON summary of what the next step would create -- counts by
   service and by mapping confidence, plus records it would skip as
   incomplete -- without writing anything. Review this before proceeding,
   especially the `mappings.withheld_low_confidence` count (see "Low-
   confidence mappings" below).

3. **`bin/rails task_bridge:backfill_outbox_baseline`**

   Writes one `item` outbox row per existing `sync_items` row with an
   `external_id`, and one `mapping` outbox row per `sync_collections`
   membership held at `confirmed` or `inferred` confidence. Every row is
   marked as a baseline, not a live change event: its payload carries
   `provenance.detected_by: "backfill"` and a `backfilled_at` timestamp
   distinct from `observed_at`.

   Safe to run multiple times: each row's idempotency key is derived from
   already-stable identity and `observed_at` values (set by step 1), so
   `OutboxEntry`'s unique index on `idempotency_key` discards duplicate
   attempts -- the first-written row's payload is always the one that
   stands, even if later reruns would compute a slightly different
   `backfilled_at`.

4. Only once the baseline looks correct, enable publication
   (`task_bridge.web.enabled` / `TASK_BRIDGE_WEB_ENABLED`, see
   `app/services/outbox/web_publisher/config.rb`) and run
   `bin/rails task_bridge:outbox:publish`, or preview the exact batches
   first with `bin/rails task_bridge:outbox:publish_dry_run`.

## Low-confidence mappings

RDR 215 leaves open whether backfill should publish the mappings
TaskBridge holds at low confidence (`Base::SyncItem#mapping_provenance_with`
returning `manual_backfill`/`low`, usually meaning no sync-ID or title
evidence links the pair). Until the product owner decides, backfill takes
the RDR's documented default and withholds them:

- `mapping_confidence: "high"` (`source_sync_id`/`created_by_sync`
  provenance) publishes as the contract's `confirmed`.
- `mapping_confidence: "medium"` (`title_fallback` provenance) publishes as
  `inferred`.
- `mapping_confidence: "low"` is **not** enqueued. It is counted under
  `mappings.withheld_low_confidence` in both the dry run and real run
  summaries, so these memberships stay identifiable for manual cleanup or
  future Web-side review without ever reaching TaskBridge Web.

This confidence mapping is specific to the backfill; it is independent of
`Outbox::MappingEmitter`, which publishes every live sync-time membership
change regardless of confidence under its own translation table.

## Default `service_instance` for single-instance services

Services configured without an explicit instance suffix (e.g. `Omnifocus`,
not `Asana:work`) have no `source_service_instance`. Because
`service_instance` is embedded in every idempotency key and must stay
stable forever once rows are published, both backfill and the live
pipeline resolve a missing instance to a fixed `<service_type>:default`
token (for example `omnifocus:default`) via `Outbox::SourceIdentity.for`.
