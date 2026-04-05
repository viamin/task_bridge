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

  it "logs a failed service and continues syncing later services" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
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

  it "reuses preloaded service items during sync_to_primary" do
    logger = instance_double(StructuredLogger, save_service_log!: nil)
    primary_service = instance_double("Primary::Service")
    service_item = instance_double(Base::SyncItem, sync_collection_id: nil, title: "Task", incomplete?: true, provider: "Passing")
    passing_service = instance_double(
      "Passing::Service",
      friendly_name: "Passing",
      sync_strategies: [:to_primary]
    )

    allow(passing_service).to receive(:items_to_sync).with(tags: []).and_return([service_item])
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

    expect(passing_service).to have_received(:items_to_sync).with(tags: []).once
    expect(passing_service).to have_received(:sync_to_primary).with(primary_service, service_items: [service_item])
  end

  def stub_sync_defaults(services:, quiet: false)
    Thread.current[:global_options] = {
      primary: "Primary",
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
end
