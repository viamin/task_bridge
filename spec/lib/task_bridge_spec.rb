# frozen_string_literal: true

require "spec_helper"

RSpec.describe TaskBridge do
  let(:logger) do
    instance_double(
      StructuredLogger,
      sync_data_for: {},
      last_synced: nil,
      save_service_log!: nil,
      summarize_service_run: nil,
      print_run_summary: nil,
      print_logs: nil
    )
  end
  let(:primary_service) do
    instance_double(
      "PrimaryService",
      friendly_name: "Omnifocus",
      sync_strategies: [:from_primary]
    )
  end
  let(:service_double) do
    instance_double(
      "TaskBridgeWebService",
      friendly_name: "TaskBridge Web",
      authorized: authorized,
      sync_strategies: sync_strategies,
      sync_from_primary: { service: "TaskBridge Web", status: "success" },
      sync_to_primary: { service: "TaskBridge Web", status: "success" },
      prune: nil
    )
  end
  let(:authorized) { true }
  let(:sync_strategies) { [:from_primary, :to_primary] }
  let(:base_options) do
    {
      primary: "Omnifocus",
      tags: ["Work"],
      personal_tags: [],
      work_tags: [],
      services: ["TaskBridgeWeb"],
      list: "Inbox",
      repositories: [],
      reminders_mapping: nil,
      max_age: 0,
      update_ids_for_existing: false,
      delete: delete_option,
      only_from_primary: false,
      only_to_primary: only_to_primary_option,
      pretend: false,
      quiet: true,
      force: false,
      verbose: false,
      log_file: "log/task_bridge.log",
      debug: false,
      console: false,
      history: false,
      testing: false
    }
  end
  let(:delete_option) { false }
  let(:only_to_primary_option) { false }
  let(:cli_options) { Marshal.load(Marshal.dump(base_options)) }

  before do
    allow(Optimist).to receive(:options) { |_opts, &_block| cli_options }
    allow(TaskBridge).to receive(:supported_services).and_return(["TaskBridgeWeb"])
    allow(StructuredLogger).to receive(:new).and_return(logger)
    allow(Omnifocus::Service).to receive(:new).and_return(primary_service)
    allow(TaskBridgeWeb::Service).to receive(:new).and_return(service_double)
  end

  describe "#call" do
    context "when a service is authorized" do
      it "runs the configured sync strategies" do
        expect(service_double).to receive(:sync_from_primary).with(primary_service).and_return({ status: "from" })
        expect(service_double).to receive(:sync_to_primary).with(primary_service).and_return({ status: "to" })

        TaskBridge.new.call
      end
    end

    context "when the service reports unauthorized" do
      let(:authorized) { false }
      let(:cli_options) { Marshal.load(Marshal.dump(base_options)) }

      it "skips the service and records the result" do
        expect(logger).to receive(:save_service_log!) do |logs|
          expect(logs.first.fetch("status")).to eq("skipped")
        end

        TaskBridge.new.call
      end
    end

    context "when delete mode is enabled" do
      let(:delete_option) { true }
      let(:cli_options) { Marshal.load(Marshal.dump(base_options)).merge(delete: true) }

      it "prunes the service instead of syncing" do
        expect(service_double).to receive(:prune)
        TaskBridge.new.call
      end
    end

    context "when only_to_primary mode is enabled" do
      let(:only_to_primary_option) { true }
      let(:sync_strategies) { [:to_primary] }
      let(:cli_options) { Marshal.load(Marshal.dump(base_options)).merge(only_to_primary: true) }

      it "only syncs to the primary service" do
        expect(service_double).to receive(:sync_to_primary).with(primary_service)
        expect(service_double).not_to receive(:sync_from_primary)

        TaskBridge.new.call
      end
    end
  end
end
