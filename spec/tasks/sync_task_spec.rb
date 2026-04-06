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

    allow(failing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_raise(RuntimeError, "boom")
    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01 09:00AM",
        last_successful: "2024-01-01 09:00AM",
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
      expect { invoke_task }.not_to raise_error
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
          "last_successful" => "2024-01-01 09:00AM",
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

    allow(failing_service).to receive(:items_to_sync).with(tags: []).and_raise(RuntimeError, "fetch boom")
    allow(passing_service).to receive(:items_to_sync).with(tags: []).and_return([])
    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01 09:00AM",
        last_successful: "2024-01-01 09:00AM",
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
      expect { invoke_task("--only-from-primary") }.not_to raise_error
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

    allow(passing_service).to receive(:items_to_sync).with(tags: [], only_modified_dates: true).and_return([service_item])
    allow(passing_service).to receive(:sync_to_primary).with(primary_service, service_items: [service_item]).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01 09:00AM",
        last_successful: "2024-01-01 09:00AM",
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

    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01 09:00AM",
        last_successful: "2024-01-01 09:00AM",
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

    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: [passing_item]).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01 09:00AM",
        last_successful: "2024-01-01 09:00AM",
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
      expect { invoke_task }.not_to raise_error
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

    allow(passing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_return(
      {
        service: "Passing",
        last_attempted: "2024-01-01 09:00AM",
        last_successful: "2024-01-01 09:00AM",
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
    expect(state.last_successful_at).to eq(Time.zone.parse("2024-01-01 09:00AM"))
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

    allow(failing_service).to receive(:sync_from_primary).with(primary_service, service_items: []).and_raise(RuntimeError, "boom")

    stub_sync_defaults(services: ["Failing"])
    allow(Chamber).to receive(:dig!).with(:task_bridge, :all_supported_services).and_return(%w[Primary Failing])
    stub_service("Primary", primary_service)
    stub_service("Failing", failing_service)
    allow(StructuredLogger).to receive(:new).and_return(logger)

    capture_output do
      expect { invoke_task }.not_to raise_error
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
    stub_const(name, namespace)
    stub_const("#{name}::Service", service_class)
    allow(service_class).to receive(:new).and_return(instance)
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
