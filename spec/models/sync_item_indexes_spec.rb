# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::SyncItem, type: :model do
  it "stores notes as text to preserve long external bodies" do
    notes_column = described_class.columns_hash["notes"]

    expect(notes_column.type).to eq(:text)
  end

  it "persists explicit source identity fields" do
    expect(described_class.columns_hash).to include(
      "source_service_name",
      "source_service_instance",
      "source_service_type",
      "source_external_id",
      "source_url",
      "source_created_at",
      "source_updated_at",
      "first_observed_at",
      "last_observed_at",
      "source_metadata"
    )
  end

  it "keeps a scoped unique index for STI external IDs per source service" do
    unique_index = described_class.connection.indexes(:sync_items).find do |index|
      index.columns == %w[type source_service_name external_id]
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

  it "keeps at most one item per source service in a sync collection" do
    collection_type_index = described_class.connection.indexes(:sync_items).find do |index|
      index.columns == %w[sync_collection_id source_service_name]
    end

    expect(collection_type_index).to be_present
    expect(collection_type_index.unique).to be(true)
    expect(collection_type_index.where).to include("sync_collection_id IS NOT NULL")
    expect(collection_type_index.where).to include("source_service_name IS NOT NULL")
  end
end
