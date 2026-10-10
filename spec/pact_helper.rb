# frozen_string_literal: true

# Consumer-side Pact configuration for the TaskBridge -> TaskBridge Web
# ingestion contract (issue #250, RDR #215).
#
# Running the consumer specs regenerates the pact file committed at
# spec/pacts/taskbridge-taskbridge_web.json. The provider repo
# (viamin/task-bridge-web) verifies against that file — no Pact Broker —
# see docs/pact-consumer-contract-testing.md and task-bridge-web#189.
require "pact/consumer/rspec"

Pact.service_consumer "TaskBridge" do
  has_pact_with "TaskBridge Web" do
    mock_service :task_bridge_web do
      # No fixed port: the mock service binds an available port so parallel
      # runs cannot collide. Specs read the bound URL from
      # `task_bridge_web.mock_service_base_url`.
    end
  end
end

# The mock service records interactions in execution order, and RSpec
# randomizes example order, so a regenerated pact would reorder with every
# seed and churn the committed file. Sort interactions by description once
# the suite has written the file (at_exit runs after RSpec's after-suite
# hook, where Pact writes the pact), reapplying the mock service's own
# empty-collection formatting so the rewrite differs from an unsorted
# write only in interaction order. Regeneration is then deterministic:
# same specs in, same bytes out, whatever the seed.
PACT_FILE_NAME = "taskbridge-taskbridge_web.json"

at_exit do
  path = File.join(Pact.configuration.pact_dir, PACT_FILE_NAME)
  next unless File.exist?(path)

  raw = File.read(path)
  pact = JSON.parse(raw)
  sorted = pact["interactions"].sort_by { |interaction| interaction["description"] }
  next if sorted == pact["interactions"]

  pact["interactions"] = sorted
  # Mirror Pact::ActiveSupportSupport#fix_json_formatting so the sorted
  # rewrite stays byte-identical to the mock service's serialization.
  formatted = JSON.pretty_generate(pact)
                  .gsub(/({\s*})(?=,?$)/, "{\n        }")
                  .gsub(/\[\s*\](?=,?$)/, "[\n        ]")
  File.write(path, formatted)
end
