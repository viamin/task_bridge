# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:prune task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:prune")
  end

  let(:task) { Rake::Task["task_bridge:outbox:prune"] }
  let(:now) { Time.zone.parse("2026-10-05T12:00:00Z") }

  before { task.reenable }

  def create_entry(status:, age:)
    entry = OutboxEntry.create!(
      idempotency_key: SecureRandom.uuid,
      record_kind: "observation",
      event_type: "snapshot_seen",
      service_type: "asana",
      service_instance: "asana:default",
      external_id: SecureRandom.uuid,
      observed_at: now - age,
      payload: { "contract_version" => 1 },
      status:
    )
    entry.update_columns(published_at: status == "delivered" ? (now - age) : nil, updated_at: now - age)
    entry
  end

  it "prunes outbox entries past their retention windows" do
    stale_delivered = create_entry(status: "delivered", age: 8.days)
    stale_failure = create_entry(status: "failed", age: 31.days)
    kept = create_entry(status: "pending", age: 2.days)

    allow(Outbox::Prune).to receive(:run!).and_call_original
    task.invoke

    expect(Outbox::Prune).to have_received(:run!)
    expect(OutboxEntry.exists?(stale_delivered.id)).to be(false)
    expect(OutboxEntry.exists?(stale_failure.id)).to be(false)
    expect(OutboxEntry.exists?(kept.id)).to be(true)
  end
end
