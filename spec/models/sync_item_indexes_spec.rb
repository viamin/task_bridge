# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::SyncItem, type: :model do
  it "stores notes as text to preserve long external bodies" do
    notes_column = described_class.columns_hash["notes"]

    expect(notes_column.type).to eq(:text)
  end

  it "keeps a scoped unique index for STI external IDs" do
    unique_index = described_class.connection.indexes(:sync_items).find do |index|
      index.columns == %w[type external_id]
    end

    expect(unique_index).to be_present
    expect(unique_index.unique).to be(true)
  end

  it "indexes last_modified for sync freshness queries" do
    last_modified_index = described_class.connection.indexes(:sync_items).find do |index|
      index.columns == ["last_modified"]
    end

    expect(last_modified_index).to be_present
  end

  it "keeps at most one item per service type in a sync collection" do
    collection_type_index = described_class.connection.indexes(:sync_items).find do |index|
      index.columns == %w[sync_collection_id type]
    end

    expect(collection_type_index).to be_present
    expect(collection_type_index.unique).to be(true)
    expect(collection_type_index.where.delete_prefix("(").delete_suffix(")")).to eq("sync_collection_id IS NOT NULL")
  end
end
