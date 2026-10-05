# frozen_string_literal: true

require "rails_helper"

RSpec.describe OutboxEntry, type: :model do
  def index_for(columns)
    described_class.connection.indexes(:outbox_entries).find { |index| index.columns == columns }
  end

  it "keeps one outbox row per idempotency key" do
    unique_index = index_for(%w[idempotency_key])

    expect(unique_index).to be_present
    expect(unique_index.unique).to be(true)
  end

  it "indexes pending rows by observed_at for the publication drain" do
    pending_index = index_for(%w[observed_at])

    expect(pending_index).to be_present
    expect(pending_index.where).to include("status = 'pending'")
  end

  it "indexes source identity lookups" do
    expect(index_for(%w[service_type service_instance external_id])).to be_present
  end

  it "indexes observed_at for time-range replay and inspection" do
    indexes = described_class.connection.indexes(:outbox_entries)

    expect(indexes.count { |index| index.columns == ["observed_at"] }).to eq(2)
  end

  it "keeps a foreign key index on sync_collection_id" do
    expect(index_for(%w[sync_collection_id])).to be_present
  end
end
