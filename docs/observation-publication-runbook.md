# Observation publication runbook (TaskBridge Web)

Operational guide for publishing normalized task facts from TaskBridge to
[TaskBridge Web](https://github.com/viamin/task-bridge-web) over the
RDR #215 contract. TaskBridge stays the deterministic layer — sync, source
observation, change detection, and reliable delivery. Durable history,
analytics, semantic retrieval, and any LLM-facing behavior live in
TaskBridge Web, which consumes the contract without knowing any source
API.

Related references:

- Contract: [rdr-215-taskbridge-observation-publication-contract.md](rdr-215-taskbridge-observation-publication-contract.md)
- What each adapter exposes: [source-capability-matrix.md](source-capability-matrix.md), [normalized-snapshot-field-support.md](normalized-snapshot-field-support.md)
- How deletions are detected safely: [source-deletion-detection.md](source-deletion-detection.md)
- Consumer contract tests: [pact-consumer-contract-testing.md](pact-consumer-contract-testing.md)

## Prerequisites

- A TaskBridge Web deployment with the `POST /api/task_bridge/v1/ingestion/batches`
  endpoint enabled and an ingestion API key issued.
- TaskBridge runs `bin/rails db:migrate` (adds `outbox_entries`, snapshot
  baselines, and provenance columns).

## Initial rollout

Run these steps in order. Every step is idempotent — rerunning any of them
is safe.

1. **Backfill provenance** so existing `sync_items` and `sync_collections`
   carry explicit source identity and mapping evidence:

   ```bash
   bin/rails task_bridge:backfill_sync_provenance
   ```

2. **Preview the baseline backfill** (counts only, nothing written):

   ```bash
   DRY_RUN=1 bin/rails task_bridge:backfill_baseline_observations
   ```

   Review the counts: `baseline` items will get one `snapshot_seen`
   observation each; `withheld` mappings are low-confidence
   (`tentative`) memberships that are deliberately not published (RDR #215
   open question — publish only `confirmed`/`inferred` mappings during
   backfill). Items counted `skipped_incomplete` lack an external ID and
   need manual review.

3. **Run the baseline backfill**:

   ```bash
   bin/rails task_bridge:backfill_baseline_observations
   ```

   This seeds current-state baseline observations and confirmed mapping
   rows into the local outbox. It never touches an external source system,
   and later syncs emit true `source_changed` history on top of the
   baseline.

4. **Preview the batches** that would be sent (NDJSON on stdout, nothing
   is delivered):

   ```bash
   bin/rails task_bridge:outbox:publish_dry_run | jq .
   ```

5. **Enable publication** in `config/settings.yml` (or the
   `TASK_BRIDGE_WEB_*` environment variables from `.env.example`):

   ```yaml
   task_bridge:
     web:
       enabled: true
       base_url: https://taskbridge-web.example.com
       api_key: <ingest key>
   ```

   The API key can also be provided through a 1Password `op://` reference
   resolved by `op-cache` in your local scripts. Never commit it.

6. **Publish** the pending outbox:

   ```bash
   bin/rails task_bridge:outbox:publish
   ```

   A run prints how many rows were delivered, are awaiting retry, or
   failed, across how many batches, plus the reason it stopped early if it
   did.

7. **Verify ingestion in TaskBridge Web** (its dashboards or API): the
   baseline `snapshot_seen` observations, mapping rows, and sync-run
   correlations should be visible for each enabled service.

8. **Schedule routine operation** alongside your existing sync schedule
   (for example in launchd): after each sync, run
   `task_bridge:outbox:publish`; periodically run
   `task_bridge:outbox:prune` to drop delivered rows after
   `task_bridge.outbox.retention.delivered_days` (default 7) and reviewed
   terminal failures after `failed_days` (default 30). Pending rows are
   never pruned.

## Routine operations

- **Retries are automatic.** Retryable failures (network errors, 429, 5xx,
  oversized batches) stay pending with exponential backoff and jitter
  (`task_bridge.web.retry_backoff_*_seconds`, default base 60s / max 1h)
  and are resent by the next `task_bridge:outbox:publish`.
- **Terminal failures** (`failed` rows — for example an invalid payload
  the server explicitly rejected as non-retryable, or a 401/422) stay in
  the outbox for operator review. Inspect `error_class`/`error_message`
  on the row, fix the cause, then replay from the Rails console:

  ```ruby
  OutboxEntry.failed.find_each(&:retry!)
  ```

  Publication rows are immutable per idempotency key, so replays are safe.
- **Stale pending rows.** Rows that stay pending across many publish runs
  are accumulating retry backoff or hitting a persistent failure; check
  their `error_message` and TaskBridge Web health before forcing a retry.
- **Re-running backfills later** (for example for a newly added service)
  is safe: the provenance and baseline backfills skip records they have
  already handled.

## Failure triage

| Symptom | Meaning | Action |
| --- | --- | --- |
| `stopped: http_401` | API key rejected | Fix `task_bridge.web.api_key`; terminal until corrected |
| `stopped: http_422` | Batch-level contract rejection | Check contract version/shape; resend corrected batch |
| row `rejected` (retryable: false) | Server rejected this row permanently | Fix the payload cause; `retry!` after |
| row `rejected` (retryable: true) or `retryable` count | Transient row/batch failure | Next publish run retries with backoff |
| `stopped: unsupported_payload_version` | Row written for a newer contract | Await the compatible endpoint rollout |
| `stopped: missing_result` | Server omitted a row result | Rows stay pending and are retried (at-least-once) |

## Privacy notes

- Normalized titles, statuses, timestamps, provider IDs/URLs, mapping
  evidence, and sync-run summaries are published. Note *content* is not:
  snapshots carry `notes_digest` (keyed HMAC), never note text.
- Google Calendar facts default to busy/free availability only
  (`google.calendar.privacy_mode: busy_only`); titles/locations/attendee
  statuses require the explicit `event_details` opt-in.
- Raw provider payloads, tokens, cookies, and authorization headers never
  enter the outbox; publisher logs carry status codes and short server
  messages only.
