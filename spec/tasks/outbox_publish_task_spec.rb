# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:publish tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:publish")
  end

  let(:publish_task) { Rake::Task["task_bridge:outbox:publish"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:publish_dry_run"] }
  let(:now) { Time.zone.parse("2026-10-05T12:00:00Z") }

  before do
    publish_task.reenable
    dry_run_task.reenable
  end

  def create_entry(key)
    OutboxEntry.create!(
      idempotency_key: key,
      record_kind: "observation",
      event_type: "snapshot_seen",
      service_type: "test_service",
      service_instance: "test_service",
      external_id: key,
      observed_at: now,
      payload: { contract_version: 1 }
    )
  end

  it "publishes pending entries through the publisher and prints the summary" do
    create_entry("k1")
    config = Outbox::WebPublisher::Config.resolve("enabled" => true, "base_url" => "https://web.example.com", "api_key" => "key")
    allow(Outbox::WebPublisher::Config).to receive(:resolve).and_return(config)
    allow(Outbox::WebPublisher::Client).to receive(:new).and_return(client_for_accepted_batch)

    output = capture_stdout { publish_task.invoke }

    expect(output).to include("Outbox publication published: 1 delivered, 0 awaiting retry, 0 failed across 1 batches")
    expect(OutboxEntry.find_by(idempotency_key: "k1")).to be_delivered
  end

  it "renders batches without sending them in the dry-run task" do
    create_entry("k1")
    create_entry("k2")

    output = capture_stdout { dry_run_task.invoke }

    expect(output).to include("Outbox dry run: would publish 2 rows across 1 batches (nothing was sent)")
    expect(output).to include("dry_run")
    expect(output).to include("k1")
    expect(OutboxEntry.pending.count).to eq(2)
  end

  it "reports disabled publication without contacting anything" do
    output = capture_stdout { publish_task.invoke }

    expect(output).to include("Outbox publication disabled")
  end

  private

  def capture_stdout
    original = $stdout
    captured = StringIO.new
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = original
  end

  def client_for_accepted_batch
    client = Object.new
    def client.post_batch(batch)
      Outbox::WebPublisher::Response.from_http(
        200,
        { results: batch.entries.map { |entry| { idempotency_key: entry.idempotency_key, status: "accepted" } } }.to_json
      )
    end
    client
  end
end
