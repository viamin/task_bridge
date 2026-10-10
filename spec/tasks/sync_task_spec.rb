# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:sync task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:sync")
  end

  let(:task) { Rake::Task["task_bridge:sync"] }
  let(:progressbar) { double("ProgressBar", log: nil, increment: nil) }

  before do
    task.reenable
    allow(ProgressBar).to receive(:create).and_return(progressbar)
  end

  after do
    Thread.current[:global_options] = nil
  end

  it "prints task usage for --help" do
    stub_sync_defaults(services: %w[Primary Failing Passing])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Failing Passing])

    output = capture_stdout do
      expect { invoke_task("--help") }.to raise_error(SystemExit)
    end

    expect(output).to include("Sync Tasks from one service to another")
    expect(output).to include("Print available command line options")
  end

  it "prints history after parsing later service overrides" do
    history_logger = instance_double(StructuredLogger, print_logs: nil)

    stub_sync_defaults(services: %w[Primary Failing Passing])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Failing Passing])
    allow(StructuredLogger).to receive(:new).with(log_file: "log/task_bridge_test.json", services: ["Passing"]).and_return(history_logger)

    expect { invoke_task("--history", "--services", "Passing") }.not_to raise_error

    expect(history_logger).to have_received(:print_logs)
  end

  it "parses task options after the rake argument separator" do
    history_logger = instance_double(StructuredLogger, print_logs: nil)

    stub_sync_defaults(services: %w[Primary Failing Passing])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Failing Passing])
    allow(StructuredLogger).to receive(:new).with(log_file: "log/task_bridge_test.json", services: ["Passing"]).and_return(history_logger)

    expect { invoke_task("task_bridge:sync", "--", "--history", "--services", "Passing") }.not_to raise_error

    expect(history_logger).to have_received(:print_logs)
  end

  it "normalizes instance-qualified service names from CLI overrides" do
    history_logger = instance_double(StructuredLogger, print_logs: nil)

    stub_sync_defaults(services: %w[Primary Asana])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Asana])
    allow(StructuredLogger).to receive(:new).with(
      log_file: "log/task_bridge_test.json",
      services: ["Asana:work", "Asana:personal"]
    ).and_return(history_logger)

    expect { invoke_task("--history", "--services", "Asana:work,Asana.personal") }.not_to raise_error

    expect(history_logger).to have_received(:print_logs)
  end

  it "passes normalized service options into service constructors" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_constructor_calls = []
    secondary_constructor_calls = []

    primary_service = instance_double(
      "Asana::Service",
      service_name: "Asana:work",
      authorized: false
    )
    secondary_service = instance_double(
      "Asana::Service",
      service_name: "Asana:personal",
      authorized: false
    )
    primary_namespace = Module.new
    primary_service_class = Class.new
    secondary_namespace = Module.new
    secondary_service_class = Class.new

    primary_service_class.define_singleton_method(:new) do |*args, **kwargs|
      primary_constructor_calls << { args:, kwargs: }
      primary_service
    end
    secondary_service_class.define_singleton_method(:new) do |*args, **kwargs|
      secondary_constructor_calls << { args:, kwargs: }
      secondary_service
    end

    stub_const("Primary", primary_namespace)
    stub_const("Primary::Service", primary_service_class)
    stub_const("Asana", secondary_namespace)
    stub_const("Asana::Service", secondary_service_class)

    stub_sync_defaults(services: ["Asana:personal"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Asana])
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task("--primary", "Primary:work") }.not_to raise_error
    end

    expect(primary_constructor_calls).to include(
      hash_including(
        kwargs: hash_including(
          options: hash_including(service_name: "Primary:work", instance_name: "work")
        )
      )
    )
    expect(secondary_constructor_calls).to include(
      hash_including(
        kwargs: hash_including(
          options: hash_including(service_name: "Asana:personal", instance_name: "personal")
        )
      )
    )
  end

  it "rejects mutually exclusive direction flags" do
    stub_sync_defaults(services: ["Passing"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing])

    expect do
      invoke_task("--only-from-primary", "--only-to-primary")
    end.to raise_error(OptionParser::InvalidOption, /mutually exclusive/)
  end

  it "raises when --primary references an unknown service class" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)

    stub_sync_defaults(services: ["Passing"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing])
    allow(StructuredLogger).to receive(:new).and_return(logger)

    expect { invoke_task("--primary", "Missing") }.to raise_error(RuntimeError, "Unknown primary service: Missing")
  end

  it "raises when a configured service constant is missing" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    primary_service = instance_double("Primary::Service")
    stub_logger_summary(logger)

    stub_sync_defaults(services: ["Missing"], primary_service:)
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Missing])
    stub_service("Primary", primary_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    expect { invoke_task("--services", "Missing") }.to raise_error(RuntimeError, "Unknown service: Missing")
  end

  it "logs a failed service and continues syncing later services" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    failing_service = instance_double(
      "Failing::Service",
      friendly_name: "Failing",
      items_to_sync: [],
      sync_strategies: [:from_primary]
    )
    passing_service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      items_to_sync: [],
      sync_strategies: [:from_primary]
    )

    allow(failing_service).to receive(:should_sync?).and_return(true)
    allow(passing_service).to receive(:should_sync?).and_return(true)
    allow(failing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_raise(RuntimeError, "boom")
    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_successful: "2024-01-01T09:00:00.000000Z",
        items_synced: 1
      }.stringify_keys
    )

    stub_sync_defaults(services: %w[Failing Passing])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Failing Passing])
    stub_service("Primary", primary_service)
    stub_service("Failing", failing_service)
    stub_service("Passing", passing_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end

    expect(failing_service).to have_received(:sync_from_primary).with(primary_service, service_items: [])
    expect(passing_service).to have_received(:sync_from_primary).with(primary_service, service_items: [])
    expect(logger).to have_received(:save_service_log!).with(
      array_including(
        hash_including(
          "service" => "Failing",
          "status" => "failed",
          "items_synced" => 0,
          "error_class" => "RuntimeError",
          "error_message" => "boom"
        )
      )
    )
    expect(logger).to have_received(:save_service_log!).with(
      array_including(
        hash_including(
          "service" => "Passing",
          "last_successful" => "2024-01-01T09:00:00.000000Z",
          "items_synced" => 1
        )
      )
    )
  end

  it "logs an item fetch failure and continues syncing later services" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    failing_service = instance_double(
      "Failing::Service",
      friendly_name: "Failing",
      sync_strategies: [:from_primary]
    )
    passing_service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      sync_strategies: [:from_primary]
    )

    allow(failing_service).to receive(:should_sync?).and_return(true)
    allow(passing_service).to receive(:should_sync?).and_return(true)
    allow(failing_service).to receive(:items_to_sync).with(tags: []).and_raise(RuntimeError, "fetch boom")
    allow(passing_service).to receive(:items_to_sync).with(tags: []).and_return([])
    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_successful: "2024-01-01T09:00:00.000000Z",
        items_synced: 1
      }.stringify_keys
    )

    stub_sync_defaults(services: %w[Failing Passing])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Failing Passing])
    stub_service("Primary", primary_service)
    stub_service("Failing", failing_service)
    stub_service("Passing", passing_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task("--only-from-primary") }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end

    expect(failing_service).to have_received(:items_to_sync).with(tags: [])
    expect(passing_service).to have_received(:sync_from_primary).with(primary_service, service_items: [])
    expect(logger).to have_received(:save_service_log!).with(
      array_including(
        hash_including(
          "service" => "Failing",
          "status" => "failed",
          "error_message" => "fetch boom"
        )
      )
    )
  end

  it "exits non-zero when a service returns a failed sync result" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    failing_service = instance_double(
      "Failing::Service",
      friendly_name: "Failing",
      items_to_sync: [],
      sync_strategies: [:from_primary]
    )
    passing_service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      items_to_sync: [],
      sync_strategies: [:from_primary]
    )

    allow(failing_service).to receive(:should_sync?).and_return(true)
    allow(passing_service).to receive(:should_sync?).and_return(true)
    allow(failing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Failing",
        status: "failed",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_failed: "2024-01-01T09:00:00.000000Z",
        items_synced: 0,
        error_class: "ProviderError",
        error_message: "provider unavailable"
      }.stringify_keys
    )
    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_successful: "2024-01-01T09:00:00.000000Z",
        items_synced: 1
      }.stringify_keys
    )

    stub_sync_defaults(services: %w[Failing Passing])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Failing Passing])
    stub_service("Primary", primary_service)
    stub_service("Failing", failing_service)
    stub_service("Passing", passing_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end

    expect(passing_service).to have_received(:sync_from_primary).with(primary_service, service_items: [])
    expect(logger).to have_received(:save_service_log!).with(
      array_including(
        hash_including(
          "service" => "Failing",
          "status" => "failed",
          "error_message" => "provider unavailable"
        )
      )
    )
  end

  it "does not preload service items for delete runs" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      sync_strategies: [:from_primary],
      items_to_sync: [],
      prune: nil
    )

    stub_sync_defaults(services: ["Passing"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing])
    stub_service("Primary", primary_service)
    stub_service("Passing", service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task("--delete") }.not_to raise_error
    end

    expect(service).to have_received(:prune)
    expect(service).not_to have_received(:items_to_sync)
  end

  it "uses modified-date reads only for to-primary when a service supports both directions" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    from_primary_item = instance_double(Base::SyncItem, sync_collection_id: nil, title: "From-primary task", incomplete?: true, provider: "Passing")
    to_primary_item = instance_double(Base::SyncItem, sync_collection_id: nil, title: "To-primary task", incomplete?: true, provider: "Passing")
    passing_service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      sync_strategies: %i[from_primary to_primary]
    )

    allow(passing_service).to receive(:should_sync?).and_return(true)
    allow(passing_service).to receive(:items_to_sync).with(tags: []).and_return([from_primary_item])
    allow(passing_service).to receive(:items_to_sync).with(tags: [], only_modified_dates: true).and_return([to_primary_item])
    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: [from_primary_item]).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_successful: "2024-01-01T09:00:00.000000Z",
        items_synced: 1
      }.stringify_keys
    )
    allow(passing_service).to receive(:sync_to_primary).with(primary_service, service_items: [to_primary_item]).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_successful: "2024-01-01T09:00:00.000000Z",
        items_synced: 1
      }.stringify_keys
    )

    stub_sync_defaults(services: ["Passing"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing])
    stub_service("Primary", primary_service)
    stub_service("Passing", passing_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task }.not_to raise_error
    end

    expect(passing_service).to have_received(:items_to_sync).with(tags: []).once
    expect(passing_service).to have_received(:items_to_sync).with(tags: [], only_modified_dates: true).once
    expect(passing_service).to have_received(:sync_from_primary).with(primary_service, service_items: [from_primary_item]).once
    expect(passing_service).to have_received(:sync_to_primary).with(primary_service, service_items: [to_primary_item]).once
  end

  it "does not preload service items when a service is skipped by should_sync?" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      sync_strategies: [:from_primary]
    )

    allow(service).to receive(:should_sync?).and_return(false)
    allow(service).to receive(:items_to_sync)
    allow(service).to receive(:sync_from_primary).with(primary_service).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        items_synced: 0,
        detail: "Sync not required"
      }.stringify_keys
    )

    stub_sync_defaults(services: ["Passing"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing])
    stub_service("Primary", primary_service)
    stub_service("Passing", service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task("--only-from-primary") }.not_to raise_error
    end

    expect(service).to have_received(:should_sync?)
    expect(service).not_to have_received(:items_to_sync)
    expect(service).to have_received(:sync_from_primary).with(primary_service)
  end

  it "records delete runs as successful service logs" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      sync_strategies: [:from_primary],
      prune: nil
    )

    stub_sync_defaults(services: ["Passing"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing])
    stub_service("Primary", primary_service)
    stub_service("Passing", service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task("--delete") }.not_to raise_error
    end

    expect(logger).to have_received(:save_service_log!).with(
      array_including(
        hash_including(
          "service" => "Passing",
          "last_attempted" => kind_of(String),
          "last_successful" => kind_of(String),
          "items_synced" => 0,
          "detail" => "Pruned completed items"
        )
      )
    )

    state = SyncServiceState.find_by!(service_name: "Passing")
    expect(state.status).to eq("success")
    expect(state.items_synced).to eq(0)
    expect(state.last_successful_at).to be_present
    expect(state.detail).to eq("Pruned completed items")
  end

  it "passes loaded service items through to sync_to_primary without refetching" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    service_item = instance_double(Base::SyncItem, sync_collection_id: nil, title: "Task", incomplete?: true, provider: "Passing")
    passing_service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      sync_strategies: [:to_primary]
    )

    allow(passing_service).to receive(:should_sync?).and_return(true)
    allow(passing_service).to receive(:items_to_sync).with(tags: [], only_modified_dates: true).and_return([service_item])
    allow(passing_service).to receive(:sync_to_primary).with(primary_service, service_items: [service_item]).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_successful: "2024-01-01T09:00:00.000000Z",
        items_synced: 1
      }.stringify_keys
    )

    stub_sync_defaults(services: ["Passing"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing])
    stub_service("Primary", primary_service)
    stub_service("Passing", passing_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task("--only-to-primary") }.not_to raise_error
    end

    expect(passing_service).to have_received(:items_to_sync).with(tags: [], only_modified_dates: true).once
    expect(passing_service).to have_received(:sync_to_primary).with(primary_service, service_items: [service_item])
  end

  it "reuses an instantiated primary service from global options" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    passing_service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      items_to_sync: [],
      sync_strategies: [:from_primary]
    )

    allow(passing_service).to receive(:should_sync?).and_return(true)
    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_successful: "2024-01-01T09:00:00.000000Z",
        items_synced: 0
      }.stringify_keys
    )

    stub_sync_defaults(services: ["Passing"], primary_service:)
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing])
    stub_service("Passing", passing_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task }.not_to raise_error
    end

    expect(passing_service).to have_received(:sync_from_primary).with(primary_service, service_items: [])
  end

  it "replaces an instantiated primary service when --primary is provided" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    default_primary_service = instance_double("Primary::Service")
    explicit_primary_service = instance_double("Alternate::Service")
    passing_service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      items_to_sync: [],
      sync_strategies: [:from_primary]
    )

    allow(passing_service).to receive(:should_sync?).and_return(false)
    allow(passing_service).to receive(:sync_from_primary).with(explicit_primary_service).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        items_synced: 0,
        detail: "Sync not required"
      }.stringify_keys
    )

    stub_sync_defaults(services: ["Passing"], primary_service: default_primary_service)
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Alternate Passing])
    stub_service("Alternate", explicit_primary_service)
    stub_service("Passing", passing_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task("--primary", "Alternate", "--only-from-primary") }.not_to raise_error
    end

    expect(passing_service).to have_received(:sync_from_primary).with(explicit_primary_service)
  end

  it "updates last_synced only for collections touched by successful services" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    synced_collection = instance_double(SyncCollection, update: true)
    passing_item = instance_double(
      Base::SyncItem,
      sync_collection_id: nil,
      title: "Passing task",
      incomplete?: true,
      provider: "Passing"
    )
    failing_item = instance_double(
      Base::SyncItem,
      sync_collection_id: nil,
      title: "Failing task",
      incomplete?: true,
      provider: "Failing"
    )
    passing_service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      items_to_sync: [passing_item],
      sync_strategies: [:from_primary]
    )
    failing_service = instance_double(
      "Failing::Service",
      friendly_name: "Failing",
      items_to_sync: [failing_item],
      sync_strategies: [:from_primary]
    )

    allow(passing_service).to receive(:should_sync?).and_return(true)
    allow(failing_service).to receive(:should_sync?).and_return(true)
    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: [passing_item]).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_successful: "2024-01-01T09:00:00.000000Z",
        items_synced: 1,
        touched_collection_ids: [101]
      }.stringify_keys
    )
    allow(failing_service).to receive(:sync_from_primary).with(primary_service, service_items: [failing_item]).and_raise(
      RuntimeError, "boom"
    )

    stub_sync_defaults(services: %w[Passing Failing])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing Failing])
    stub_service("Primary", primary_service)
    stub_service("Passing", passing_service)
    stub_service("Failing", failing_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)
    allow(SyncCollection).to receive(:find_by).with(id: 101).and_return(synced_collection)
    allow(SyncCollection).to receive(:find_by).with(id: 202).and_return(nil)

    capture_output do
      expect { invoke_task }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end

    expect(SyncCollection).to have_received(:find_by).with(id: 101)
    expect(synced_collection).to have_received(:update).with(last_synced: kind_of(ActiveSupport::TimeWithZone))
    expect(SyncCollection).not_to have_received(:find_by).with(id: 202)
  end

  it "persists service sync state in the database for successful runs" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    passing_service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      items_to_sync: [],
      sync_strategies: [:from_primary]
    )

    allow(passing_service).to receive(:should_sync?).and_return(true)
    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_successful: "2024-01-01T09:00:00.000000Z",
        items_synced: 1
      }.stringify_keys
    )

    stub_sync_defaults(services: ["Passing"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing])
    stub_service("Primary", primary_service)
    stub_service("Passing", passing_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    expect do
      capture_output { invoke_task }
    end.to change(SyncServiceState, :count).by(1)

    state = SyncServiceState.find_by!(service_name: "Passing")
    expect(state.status).to eq("success")
    expect(state.items_synced).to eq(1)
    expect(state.last_successful_at).to eq(Time.zone.parse("2024-01-01T09:00:00.000000Z"))
  end

  it "advances the activity-sync cursor when activity emit completes" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    github_service = instance_double(
      "Github::Service",
      friendly_name: "Github",
      service_name: "Github",
      items_to_sync: [],
      sync_strategies: [:to_primary],
      activity_emit_complete?: true
    )

    allow(github_service).to receive(:should_sync?).and_return(true)
    allow(github_service).to receive(:sync_to_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Github",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_successful: "2024-01-01T09:00:00.000000Z",
        items_synced: 1
      }.stringify_keys
    )

    stub_sync_defaults(services: ["Github"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Github])
    stub_service("Primary", primary_service)
    stub_service("Github", github_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)
    allow(SyncServiceState).to receive(:record_activity_sync!).and_call_original

    capture_output { invoke_task }

    expect(SyncServiceState).to have_received(:record_activity_sync!).with(service_name: "Github", at: kind_of(String))
    state = SyncServiceState.find_by!(service_name: "Github")
    expect(state.last_successful_activity_sync_at).to be_present
  end

  it "leaves the activity-sync cursor in place when activity emit fails" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    github_service = instance_double(
      "Github::Service",
      friendly_name: "Github",
      service_name: "Github",
      items_to_sync: [],
      sync_strategies: [:to_primary],
      activity_emit_complete?: false
    )
    existing_cursor = Time.zone.parse("2024-01-01T08:00:00Z")
    SyncServiceState.create!(
      service_name: "Github",
      status: "success",
      items_synced: 1,
      last_successful_at: existing_cursor,
      last_successful_activity_sync_at: existing_cursor
    )

    allow(github_service).to receive(:should_sync?).and_return(true)
    allow(github_service).to receive(:sync_to_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Github",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_successful: "2024-01-01T09:00:00.000000Z",
        items_synced: 1
      }.stringify_keys
    )

    stub_sync_defaults(services: ["Github"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Github])
    stub_service("Primary", primary_service)
    stub_service("Github", github_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output { invoke_task }

    state = SyncServiceState.find_by!(service_name: "Github")
    expect(state.last_successful_activity_sync_at).to eq(existing_cursor)
  end

  it "does not advance the activity-sync cursor when GitHub sync is skipped" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    github_service = instance_double(
      "Github::Service",
      friendly_name: "Github",
      service_name: "Github",
      sync_strategies: [:to_primary],
      activity_emit_complete?: false
    )
    existing_cursor = Time.zone.parse("2024-01-01T08:00:00Z")
    SyncServiceState.create!(
      service_name: "Github",
      status: "success",
      items_synced: 1,
      last_successful_at: existing_cursor,
      last_successful_activity_sync_at: existing_cursor
    )

    allow(github_service).to receive(:should_sync?).and_return(false)
    allow(github_service).to receive(:items_to_sync)
    allow(github_service).to receive(:sync_to_primary).with(primary_service).and_return(
      {
        service: "Github",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        items_synced: 0,
        detail: "Sync not required"
      }.stringify_keys
    )

    stub_sync_defaults(services: ["Github"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Github])
    stub_service("Primary", primary_service)
    stub_service("Github", github_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output { invoke_task }

    expect(github_service).not_to have_received(:items_to_sync)
    expect(SyncServiceState.find_by!(service_name: "Github").last_successful_activity_sync_at).to eq(existing_cursor)
  end

  it "does not advance the activity-sync cursor for services without an activity emitter" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    passing_service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      service_name: "Passing",
      items_to_sync: [],
      sync_strategies: [:from_primary]
    )

    allow(passing_service).to receive(:should_sync?).and_return(true)
    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01T09:00:00.000000Z",
        last_successful: "2024-01-01T09:00:00.000000Z",
        items_synced: 1
      }.stringify_keys
    )

    stub_sync_defaults(services: ["Passing"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing])
    stub_service("Primary", primary_service)
    stub_service("Passing", passing_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)
    expect(SyncServiceState).not_to receive(:record_activity_sync!)

    capture_output { invoke_task }
  end

  it "does not advance the activity-sync cursor when the service run itself failed" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    github_service = instance_double(
      "Github::Service",
      friendly_name: "Github",
      service_name: "Github",
      items_to_sync: [],
      sync_strategies: [:to_primary],
      activity_emit_complete?: true
    )

    allow(github_service).to receive(:should_sync?).and_return(true)
    allow(github_service).to receive(:sync_to_primary).and_raise(RuntimeError, "github is down")

    stub_sync_defaults(services: ["Github"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Github])
    stub_service("Primary", primary_service)
    stub_service("Github", github_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)
    expect(SyncServiceState).not_to receive(:record_activity_sync!)

    capture_output do
      expect { invoke_task }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end

  it "preserves the previous successful sync timestamp when a later run fails" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    failing_service = instance_double(
      "Failing::Service",
      friendly_name: "Failing",
      items_to_sync: [],
      sync_strategies: [:from_primary]
    )
    SyncServiceState.create!(
      service_name: "Failing",
      status: "success",
      items_synced: 2,
      last_successful_at: Time.zone.parse("2024-01-01 08:00AM")
    )

    allow(failing_service).to receive(:should_sync?).and_return(true)
    allow(failing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_raise(RuntimeError, "boom")

    stub_sync_defaults(services: ["Failing"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Failing])
    stub_service("Primary", primary_service)
    stub_service("Failing", failing_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end

    state = SyncServiceState.find_by!(service_name: "Failing")
    expect(state.status).to eq("failed")
    expect(state.last_successful_at).to eq(Time.zone.parse("2024-01-01 08:00AM"))
    expect(state.last_failed_at).to be_present
  end

  it "does not persist sync collections from title-only matches during item gathering" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    stub_logger_summary(logger)
    primary_service = instance_double("Primary::Service")
    service_a_item = instance_double(
      Base::SyncItem,
      sync_collection_id: nil,
      title: "Shared title",
      incomplete?: true,
      provider: "ServiceA"
    )
    service_b_item = instance_double(
      Base::SyncItem,
      sync_collection_id: nil,
      title: "Shared title",
      incomplete?: true,
      provider: "ServiceB"
    )
    service_a = instance_double("ServiceA::Service", friendly_name: "ServiceA", items_to_sync: [service_a_item], sync_strategies: [])
    service_b = instance_double("ServiceB::Service", friendly_name: "ServiceB", items_to_sync: [service_b_item], sync_strategies: [])
    allow(service_a).to receive(:should_sync?).and_return(true)
    allow(service_b).to receive(:should_sync?).and_return(true)

    stub_sync_defaults(services: %w[ServiceA ServiceB])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary ServiceA ServiceB])
    stub_service("Primary", primary_service)
    stub_service("ServiceA", service_a)
    stub_service("ServiceB", service_b)
    allow(StructuredLogger).to receive(:new).and_return(logger)
    allow(SyncCollection).to receive(:create)

    capture_output do
      expect { invoke_task }.not_to raise_error
    end

    expect(SyncCollection).not_to have_received(:create)
  end

  describe "outbox publication" do
    let(:logger) { instance_double(StructuredLogger, save_service_log!: nil) }
    let(:primary_service) { instance_double("Primary::Service") }
    let(:service) do
      service = instance_double("Passing::Service", friendly_name: "Passing", items_to_sync: [], sync_strategies: [:from_primary])
      allow(service).to receive(:should_sync?).and_return(true)
      allow(service).to receive(:sync_from_primary).and_return({ "service" => "Passing", "status" => "success", "items_synced" => 1 })
      service
    end
    let(:publication_summary) do
      { status: "published", batches: 1, delivered: 2, retryable: 0, failed: 0 }
    end

    before do
      stub_logger_summary(logger)
      allow(Outbox::WebPublisher).to receive(:run!).and_return(publication_summary)
      stub_sync_defaults(services: ["Passing"])
      allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing])
      stub_service("Primary", primary_service)
      stub_service("Passing", service)
      allow(StructuredLogger).to receive(:new).and_return(logger)
    end

    it "publishes the outbox at the end of the run" do
      stdout, = capture_output do
        expect { invoke_task }.not_to raise_error
      end

      expect(Outbox::WebPublisher).to have_received(:run!)
      expect(stdout).to include("Published 2 outbox rows to TaskBridge Web (published)")
    end

    it "keeps the sync run green when publication fails" do
      allow(Outbox::WebPublisher).to receive(:run!).and_raise(StandardError, "connection refused")

      stdout, stderr = capture_output do
        expect { invoke_task }.not_to raise_error
      end

      expect(stdout).not_to include("Published")
      expect(stderr).to include("Outbox publication failed; rows stay pending for retry")
      expect(SyncServiceState.find_by!(service_name: "Passing").status).to eq("success")
    end

    it "does not publish during pretend runs" do
      capture_output do
        expect { invoke_task("-x") }.not_to raise_error
      end

      expect(Outbox::WebPublisher).not_to have_received(:run!)
    end

    it "stays quiet about disabled publication" do
      allow(Outbox::WebPublisher).to receive(:run!).and_return(publication_summary.merge(status: "disabled"))

      stdout, = capture_output do
        expect { invoke_task }.not_to raise_error
      end

      expect(stdout).not_to include("TaskBridge Web")
    end

    it "warns when publication is enabled but not configured" do
      allow(Outbox::WebPublisher).to receive(:run!).and_return(publication_summary.merge(status: "not_configured"))

      stdout, stderr = capture_output do
        expect { invoke_task }.not_to raise_error
      end

      expect(stdout).not_to include("Published")
      expect(stderr).to include("enabled but missing its base URL or API key")
    end

    it "reports why an incomplete publication stopped" do
      allow(Outbox::WebPublisher).to receive(:run!).and_return(
        publication_summary.merge(status: "incomplete", delivered: 0, retryable: 2, stopped_reason: "http_413")
      )

      stdout, = capture_output do
        expect { invoke_task }.not_to raise_error
      end

      expect(stdout).to include("Published 0 outbox rows to TaskBridge Web (incomplete, stopped: http_413)")
    end
  end

  describe "sync-run summaries" do
    let(:logger) { instance_double(StructuredLogger, save_service_log!: nil) }
    let(:primary_service) { instance_double("Primary::Service") }

    before do
      stub_logger_summary(logger)
      stub_sync_defaults(services: ["Passing"])
      allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Passing])
      stub_service("Primary", primary_service)
      allow(StructuredLogger).to receive(:new).and_return(logger)
    end

    it "enqueues one summary row for a successful service run" do
      service = instance_double(
        "Passing::Service", friendly_name: "Passing", service_name: "Passing",
                            items_to_sync: [], sync_strategies: [:from_primary]
      )
      allow(service).to receive(:should_sync?).and_return(true)
      allow(service).to receive(:sync_from_primary).and_return(
        {
          "service" => "Passing",
          "last_attempted" => "2024-01-01T09:00:00.000000Z",
          "last_successful" => "2024-01-01T09:00:00.000000Z",
          "items_synced" => 1,
          "touched_collection_ids" => [7]
        }.stringify_keys
      )
      stub_service("Passing", service)

      expect do
        capture_output { invoke_task }
      end.to change { OutboxEntry.where(record_kind: "sync_run").count }.by(1)

      row = OutboxEntry.find_by(record_kind: "sync_run")
      expect(row.idempotency_key).to eq("tb:v1:sync_run:passing:sync-run-20240101T090000Z-passing")
      expect(row.payload).to include(
        "sync_run_id" => "sync-run-20240101T090000Z-passing",
        "service_type" => "passing",
        "service_instance" => "passing",
        "started_at" => "2024-01-01T09:00:00.000000Z",
        "status" => "success",
        "items_synced" => 1,
        "touched_collection_ids" => [7]
      )
    end

    it "enqueues a failed summary with the structured run error" do
      service = instance_double(
        "Passing::Service", friendly_name: "Passing", service_name: "Passing",
                            items_to_sync: [], sync_strategies: [:from_primary]
      )
      allow(service).to receive(:should_sync?).and_return(true)
      allow(service).to receive(:sync_from_primary).and_raise(RuntimeError, "boom")
      stub_service("Passing", service)

      capture_output do
        expect { invoke_task }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      end

      row = OutboxEntry.find_by(record_kind: "sync_run")
      expect(row.payload).to include(
        "status" => "failed",
        "items_synced" => 0,
        "error" => { "class" => "RuntimeError", "message" => "boom", "retryable" => false }
      )
    end

    it "enqueues nothing for pretend runs" do
      service = instance_double(
        "Passing::Service", friendly_name: "Passing", service_name: "Passing",
                            items_to_sync: [], sync_strategies: [:from_primary]
      )
      allow(service).to receive(:should_sync?).and_return(true)
      allow(service).to receive(:sync_from_primary).and_return(
        { "service" => "Passing", "status" => "success", "items_synced" => 0 }.stringify_keys
      )
      stub_service("Passing", service)

      capture_output { invoke_task("-x") }

      expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    end
  end

  def stub_sync_defaults(services:, quiet: false, primary_service: nil)
    Thread.current[:global_options] = {
      primary: "Primary",
      primary_service: primary_service,
      tags: [],
      services: services,
      personal_tags: [],
      work_tags: [],
      list: nil,
      repositories: [],
      reminders_mapping: nil,
      max_age: 0,
      update_ids_for_existing: false,
      delete: false,
      only_from_primary: false,
      only_to_primary: false,
      pretend: false,
      quiet: quiet,
      force: false,
      verbose: false,
      log_file: "log/task_bridge_test.json",
      debug: false,
      history: false,
      testing: true
    }
  end

  def stub_service(name, instance)
    namespace = Module.new
    service_class = Class.new
    service_class.define_singleton_method(:new) { |_args = nil, **_kwargs| instance }
    stub_const(name, namespace)
    stub_const("#{name}::Service", service_class)
  end

  def invoke_task(*args)
    original_argv = ARGV.dup
    ARGV.replace(args)
    task.invoke
  ensure
    ARGV.replace(original_argv)
  end

  def capture_stdout
    previous_stdout = $stdout
    captured = StringIO.new
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = previous_stdout
  end

  def capture_output
    previous_stdout = $stdout
    previous_stderr = $stderr
    captured_stdout = StringIO.new
    captured_stderr = StringIO.new
    $stdout = captured_stdout
    $stderr = captured_stderr
    yield
    [captured_stdout.string, captured_stderr.string]
  ensure
    $stdout = previous_stdout
    $stderr = previous_stderr
  end

  def stub_logger_summary(logger)
    allow(logger).to receive(:summarize_service_run) do |service_name:, logs:|
      normalized_logs = Array(logs)
      failed = normalized_logs.any? { |entry| entry["status"] == "failed" }
      status = if failed
        "failed"
      elsif normalized_logs.any?
        "success"
      else
        "idle"
      end

      {
        service: service_name,
        status: status,
        items_synced: normalized_logs.sum { |entry| entry.fetch("items_synced", 0).to_i },
        last_attempted: normalized_logs.filter_map { |entry| entry["last_attempted"] }.last,
        last_successful: normalized_logs.filter_map { |entry| entry["last_successful"] }.last,
        last_failed: normalized_logs.filter_map { |entry| entry["last_failed"] }.last,
        detail: normalized_logs.filter_map { |entry| entry["detail"] }.last
      }
    end
  end
end
