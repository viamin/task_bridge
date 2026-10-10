# frozen_string_literal: true

# Consumer-side Pact configuration for the TaskBridge -> TaskBridge Web
# ingestion contract (issue #250, RDR #215).
#
# Running the consumer specs regenerates the pact file committed at
# spec/pacts/taskbridge-taskbridge_web.json. The provider repo
# (viamin/task-bridge-web) verifies against that file — no Pact Broker —
# see docs/pact-consumer-contract-testing.md and task-bridge-web#189.
require "pact/consumer/rspec"
require "pact/consumer_contract/file_name"

Pact.service_consumer "TaskBridge" do
  has_pact_with "TaskBridge Web" do
    mock_service :task_bridge_web do
      # No fixed port: the mock service binds an available port so parallel
      # runs cannot collide. Specs read the bound URL from
      # `task_bridge_web.mock_service_base_url`.
    end
  end
end

# The mock service records interactions in example execution order, which
# RSpec randomizes per seed. Sort the written pact's interactions by
# description (then provider state) so regenerating the committed pact is
# deterministic: the file only changes when the contract itself changes.
module DeterministicPactInteractions
  def write_pact
    super
    sort_written_interactions
  end

  private

  def sort_written_interactions
    path = Pact::FileName.file_path(
      @consumer_contract_details.fetch(:consumer).fetch(:name),
      @consumer_contract_details.fetch(:provider).fetch(:name),
      @consumer_contract_details.fetch(:pact_dir)
    )
    sort_pact_file(path)
  end

  def sort_pact_file(path)
    pact = JSON.parse(File.read(path))
    pact["interactions"] = pact["interactions"].sort_by do |interaction|
      [interaction["description"], interaction["providerState"].to_s]
    end
    File.write(path, JSON.pretty_generate(pact))
  end
end

Pact::Consumer::ConsumerContractBuilder.prepend(DeterministicPactInteractions)
