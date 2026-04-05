# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::SyncItem, type: :model do
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
end
