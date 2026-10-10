# Pact consumer contract tests: Outbox::WebPublisher → TaskBridge Web

- Status: Delivered evaluation spike (#250)
- Contract of record: RDR #215 (`docs/rdr-215-taskbridge-observation-publication-contract.md`)
- Provider-side verification: viamin/task-bridge-web#189
- OpenAPI / Schemathesis alternative: viamin/task-bridge-web#190

TaskBridge publishes outbox batches to TaskBridge Web's ingestion endpoint
(`POST /api/task_bridge/v1/ingestion/batches`). That contract previously
existed only implicitly in `Outbox::WebPublisher` and its unit test doubles.
This spike adds **consumer-driven contract tests with [Pact](https://pact.io)**:
the consumer specs run the real publisher against a Pact mock service, and
the recorded pact file is committed so the provider repo can verify it.

## What exists here

| File | Role |
| --- | --- |
| `Gemfile` | `pact` gem in the `:test` group (consumer role); `json` pinned `< 3` (see caveats) |
| `spec/pact_helper.rb` | Consumer config: consumer `TaskBridge`, provider `TaskBridge Web`, in-process mock service on an ephemeral port |
| `spec/services/outbox/web_publisher/task_bridge_web_contract_spec.rb` | Consumer specs (tagged `pact: true`) |
| `spec/pacts/taskbridge-taskbridge_web.json` | Committed pact file (specification version 2) — regenerate, don't hand-edit |

Unlike the unit specs (which stub the client), the consumer specs drive the
full publisher stack — real `Client`, real `Net::HTTP` transport, real
`Batch` serialization, real `Response`/`Reconciler` reduction — against the
mock service, so the pact reflects actual wire behavior.

Covered interactions:

1. **Successful v1 batch** (item snapshot + two observations) with a
   per-row `results` response covering all three row outcomes — `replayed`
   (item), `accepted` (observation), `rejected` + `retryable: false`
   (terminal observation). Asserts outbox reconciliation: delivered,
   delivered, failed-with-`error_code`.
2. **413 on a two-row batch** → publisher halves it and re-sends two
   single-row batches, each answered `200` with `accepted` results.
3. **413 even on a single row** → ordinary retryable row failure (row stays
   pending, run stops with `http_413`).
4. **401 unauthorized** (revoked API key) → terminal failure for every row.

Pact request matching is strict (extra keys or wrong array lengths fail),
so the expected bodies pin the exact v1 request shape: headers
(`Authorization`, `X-TaskBridge-Contract-Version`, `X-TaskBridge-Batch-Id`
as a UUID regex, `X-TaskBridge-Sent-At` as an ISO 8601 regex), the four
top-level record arrays, and every row field. Only genuinely variable
values use matchers (`batch_id`, `sent_at`, `publisher_instance`,
server-provided error messages, count fields).

## Running and regenerating the pact

```bash
bundle exec rspec spec/services/outbox/web_publisher/task_bridge_web_contract_spec.rb
```

- The pact file is rewritten from the run's verified interactions
  (`pactfile_write_mode: overwrite`). Run the **whole file**, not
  `--example` subsets, before committing it.
- Interactions are sorted by description at write time
  (`spec/pact_helper.rb`), so regeneration is deterministic: whatever the
  RSpec seed, the same specs produce the same bytes and the committed
  file only changes when the contract actually changes.
- CI runs it with the rest of the suite (`bundle exec rspec --tag ~no_ci`).
- Mock-service logs land in `log/` (gitignored).

## How the provider repo should pick this up (viamin/task-bridge-web#189)

File-based exchange, no Pact Broker (revisit only if `can-i-deploy` gating
becomes a requirement):

1. Add the gem to task-bridge-web's `:test` group:

   ```ruby
   gem "pact"
   ```

2. Point provider verification at the committed pact file. With sibling
   checkouts (simplest for local runs):

   ```ruby
   # spec/pact_helper.rb (provider side)
   require "pact/provider/rspec"

   Pact.service_provider "TaskBridge Web" do
     honours_pact_with "TaskBridge" do
       pact_uri "../task_bridge/spec/pacts/taskbridge-taskbridge_web.json"
     end
   end
   ```

   In CI, fetch the file instead of relying on a sibling checkout (CI
   download step, or a small script that pulls it from the task_bridge
   repo at the SHA under test).

3. Implement the four provider states the pact declares (set up data /
   environment before replaying each interaction):

   | Provider state | Required setup |
   | --- | --- |
   | `an empty ingestion outbox except an item snapshot for tb:v1:item:asana:workspace-12345:default:1201234567890:snapshot:2026-10-05T10:00:00.000000Z was already accepted` | Clean ingestion tables; seed the item row with that idempotency key so it replays as `replayed` |
   | `a one-row-per-batch ingestion limit` | Make the two-row batch POST return `413` while single-row POSTs succeed (e.g. a test-only configurable row limit) |
   | `an ingestion limit that rejects even a single row` | Make any batch POST return `413` |
   | `an ingestion API key that has been revoked` | Configure `pact-ingest-key` as valid and `revoked-ingest-key` as invalid |

   Sketch:

   ```ruby
   Pact.provider_states_for "TaskBridge" do
     provider_state "an ingestion limit that rejects even a single row" do
       set_up do
         # e.g. ENV["INGESTION_MAX_ROWS_PER_BATCH"] = "0"
       end
     end
   end
   ```

4. Run `bundle exec rake pact:verify` (or the RSpec task) against the
   running provider application.

Note on the 413 interactions: if the provider does not want a
test-configurable payload limit, the alternatives are replaying those two
interactions against a Rack-level stub (weaker) or dropping them from
provider verification and relying on the consumer-side halving specs.
That trade-off belongs to #189.

The pact replays requests with the static examples recorded here — notably
the API keys `pact-ingest-key` (valid) and `revoked-ingest-key` (invalid).
These are fixtures; never record a real credential into a pact file.

## Findings

- **Effort:** roughly a day for this spike, most of it spent choosing the
  interaction set (what the publisher actually depends on) and pinning
  dynamic fields with matchers. The plumbing itself is small: one helper
  file, one spec file, two Gemfile lines.
- **Maintenance burden:** low and front-loaded. The spec mirrors the v1
  wire shape; it changes only when the contract changes — which is exactly
  when the provider needs to hear about it. Strict request matching means
  a publisher refactor that alters the body fails here before it ships.
- **CI runtime:** +0.8 s wall clock on the suite (712 → 716 examples,
  6.9 s → 7.7 s). The mock service is an in-process WEBrick thread; no
  extra service, port is allocated dynamically.
- **Would it catch realistic drift?** Yes, in both directions:
  - Provider drift: if TaskBridge Web renamed `results` (e.g. to a
    `row_results` envelope), changed the `status` enum values, dropped
    `retryable`/`error_code` from rejected rows, or stopped echoing
    per-row `idempotency_key`, provider verification of this pact fails —
    those fields are exact/type-matched in the response expectations.
    Verified against the committed pact with Pact's own response matcher:
    a conforming response (extra keys, different `batch_id`, any integer
    counts, different message text) matches, while renaming `results` →
    `row_results` or changing a `status` enum value (`accepted` → `ok`)
    both fail verification.
  - Consumer drift: if `Batch` serialization changed (renamed field,
    missing required header, altered row shape), the consumer specs fail
    immediately because request matching is strict.
  - Not covered by matchers: the count invariant
    (`accepted + replayed + rejected == results.length`) is only
    type-matched and stays the provider's own unit-test responsibility.
- **Caveat — json pin:** `pact` 1.67 marshals matchers between the spec
  and its in-process mock service using JSON `json_class` additions, which
  json 3.x removed. The Gemfile pins `json ~> 2.10`; revisit when
  pact-ruby ships json 3 support.
- **Caveat — no broker:** file-based exchange means no
  `can-i-deploy` gating; coordination is by PR review plus CI running the
  (cheap) consumer suite. Revisit a broker only if release gating between
  the two repos becomes a real requirement.

## Non-goals (unchanged from #250)

- No changes to `WebPublisher` behavior — the spike added tests only.
- Provider-side verification implementation → viamin/task-bridge-web#189.
- Pact Broker deployment.
