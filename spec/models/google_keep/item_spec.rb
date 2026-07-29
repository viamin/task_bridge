# frozen_string_literal: true

require "rails_helper"

RSpec.describe GoogleKeep::Item do
  include_context "full_options"
  let(:service_names) { %w[Asana Reminders Github GoogleTasks Instapaper] }

  let(:note) { OpenStruct.new(title: "Groceries", update_time: Time.zone.parse("2024-04-03 10:00:00 UTC")) }
  let(:child_item) do
    OpenStruct.new(
      text: OpenStruct.new(text: "Oat milk"),
      checked: true,
      child_list_items: []
    )
  end
  let(:root_item) do
    OpenStruct.new(
      text: OpenStruct.new(text: "Buy milk"),
      checked: false,
      child_list_items: [child_item]
    )
  end
  let(:item) do
    described_class.new(
      keep_item: {
        note:,
        note_title: note.title,
        item: root_item,
        path: [0]
      },
      options:
    )
  end

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(Time.current - 1.day)
    item.read_original
  end

  describe "#read_original" do
    it "reads the title, completion state, and shallow nesting from a Keep list item" do
      expect(item.title).to eq("Buy milk")
      expect(item.completed?).to be(false)
      expect(item.project).to eq("Groceries")
      expect(item.sub_item_count).to eq(1)
      expect(item.sub_items.first.title).to eq("Oat milk")
      expect(item.sub_items.first.completed?).to be(true)
    end

    it "keeps child items hydrated in metadata-only reads" do
      metadata_item = described_class.new(
        keep_item: {
          note:,
          note_title: note.title,
          item: root_item,
          path: [0]
        },
        options:
      )

      metadata_item.read_original(only_modified_dates: true)

      expect(metadata_item.sub_item_count).to eq(1)
      expect(metadata_item.sub_items.first.title).to eq("Oat milk")
    end
  end

  describe "#external_sync_notes" do
    it "stores a stable Keep sync id" do
      expect(item.external_sync_notes).to include("google_keep_id: Groceries::0::Buy milk::open")
    end
  end
end
