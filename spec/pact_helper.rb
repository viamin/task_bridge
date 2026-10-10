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

# Interactions are recorded in example execution order, which RSpec
# randomizes, so regenerating the committed pact with a different seed would
# otherwise produce order-only churn against the file the provider verifies.
# Sort them once Pact has written the file (its after(:suite) hook runs
# before process exit; after(:suite) hooks fire in reverse registration
# order, so at_exit is the reliable place to run second).
at_exit do
  pact_path = File.expand_path("pacts/taskbridge-taskbridge_web.json", __dir__)
  next unless File.exist?(pact_path)

  pact = JSON.parse(File.read(pact_path))
  interactions = pact["interactions"].sort_by { |interaction| interaction["description"] }
  next if interactions.length < 2 || interactions == pact["interactions"]

  pact["interactions"] = interactions
  File.write(pact_path, JSON.pretty_generate(pact))
end
