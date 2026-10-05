# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::Prune do
  let(:now) { Time.zone.parse("2026-10-05T12:00:00Z") }

  def create_entry(status:, age:, published: false)
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
    entry.update_columns(
      published_at: published ? (now - age) : nil,
      updated_at: now - age
    )
    entry
  end

  it "prunes delivered entries past the delivered retention window" do
    stale = create_entry(status: "delivered", age: 8.days, published: true)
    recent = create_entry(status: "delivered", age: 6.days, published: true)

    pruned = described_class.run!(now:)

    expect(OutboxEntry.exists?(stale.id)).to be(false)
    expect(OutboxEntry.exists?(recent.id)).to be(true)
    expect(pruned).to include(delivered: 1)
  end

  it "prunes delivered entries without a published_at by updated_at" do
    stale = create_entry(status: "delivered", age: 8.days, published: false)

    described_class.run!(now:)

    expect(OutboxEntry.exists?(stale.id)).to be(false)
  end

  it "prunes terminal failures only past the longer operator-review window" do
    stale_failure = create_entry(status: "failed", age: 31.days)
    recent_failure = create_entry(status: "failed", age: 29.days)

    pruned = described_class.run!(now:)

    expect(OutboxEntry.exists?(stale_failure.id)).to be(false)
    expect(OutboxEntry.exists?(recent_failure.id)).to be(true)
    expect(pruned).to include(failed: 1)
  end

  it "never prunes pending entries regardless of age" do
    old_pending = create_entry(status: "pending", age: 1.year)

    described_class.run!(now:)

    expect(OutboxEntry.exists?(old_pending.id)).to be(true)
  end

  it "reads the retention windows from task_bridge.outbox.retention settings" do
    allow(Chamber).to receive(:dig).with(:task_bridge, :outbox, :retention, :delivered_days).and_return(1)
    allow(Chamber).to receive(:dig).with(:task_bridge, :outbox, :retention, :failed_days).and_return(90)
    recently_delivered = create_entry(status: "delivered", age: 2.days, published: true)
    failed_within_default = create_entry(status: "failed", age: 31.days)

    described_class.run!(now:)

    expect(OutboxEntry.exists?(recently_delivered.id)).to be(false)
    expect(OutboxEntry.exists?(failed_within_default.id)).to be(true)
  end
end
