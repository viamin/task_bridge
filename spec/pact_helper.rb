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
