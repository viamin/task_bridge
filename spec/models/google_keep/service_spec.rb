# frozen_string_literal: true

require "rails_helper"

RSpec.describe GoogleKeep::Service do
  include_context "full_options"
  let(:options) { full_options.merge(list: "My Tasks") }

  let(:keep_service) { instance_double(Google::Apis::KeepV1::KeepService, "authorization=": true) }
  let(:service) { described_class.new(options:, keep_service:, authorization: {}) }
  let(:last_sync) { Time.current - 1.day }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(last_sync)
  end

  describe "#sync_strategies" do
    it "supports syncing to and from the primary service" do
      expect(service.sync_strategies).to contain_exactly(:from_primary, :to_primary)
    end
  end

  describe "#items_to_sync" do
    subject(:items_to_sync) { service.items_to_sync }

    let(:nested_item) do
      Google::Apis::KeepV1::ListItem.new(
        text: Google::Apis::KeepV1::TextContent.new(text: "Chives"),
        checked: true
      )
    end
    let(:root_item) do
      Google::Apis::KeepV1::ListItem.new(
        text: Google::Apis::KeepV1::TextContent.new(text: "Buy milk"),
        checked: false,
        child_list_items: [nested_item]
      )
    end
    let(:note_body) do
      Google::Apis::KeepV1::Section.new(
        list: Google::Apis::KeepV1::ListContent.new(list_items: [root_item])
      )
    end
    let(:note) do
      Google::Apis::KeepV1::Note.new(
        name: "notes/123",
        title: options[:list],
        body: note_body
      )
    end
    let(:notes_response) { double("notes_response", notes: [note]) }

    before do
      allow(keep_service).to receive(:list_notes).with(page_size: 100).and_return(notes_response)
    end

    it "wraps Keep list items in sync items with stable ids" do
      expect(items_to_sync.length).to eq(1)
      expect(items_to_sync.first.external_id).to eq("My Tasks::0::Buy milk::open")
      expect(items_to_sync.first.title).to eq("Buy milk")
      expect(items_to_sync.first.completed?).to be(false)
      expect(items_to_sync.first.sub_items.first.title).to eq("Chives")
    end
  end

  describe "#sync_from_primary" do
    let(:sub_item) do
      double(
        "PrimarySubItem",
        title: "Chives",
        completed?: true,
        sub_items: []
      )
    end
    let(:primary_item) do
      double(
        "PrimaryItem",
        title: "Buy milk",
        completed?: false,
        sub_items: [sub_item]
      )
    end
    let(:primary_service) do
      instance_double(
        "Primary::Service",
        friendly_name: "Omnifocus",
        items_to_sync: [primary_item]
      )
    end
    let(:existing_note) do
      Google::Apis::KeepV1::Note.new(
        name: "notes/existing",
        title: options[:list],
        body: Google::Apis::KeepV1::Section.new(
          list: Google::Apis::KeepV1::ListContent.new(list_items: [])
        )
      )
    end

    before do
      allow(service).to receive(:should_sync?).and_return(true)
      allow(service).to receive(:keep_notes).and_return([existing_note])
    end

    it "rebuilds the note from the primary service" do
      expect(primary_service).to receive(:items_to_sync).with(tags: [service.friendly_name]).and_return([primary_item])
      expect(keep_service).to receive(:delete_note).with("notes/existing")
      expect(keep_service).to receive(:create_note) do |note|
        expect(note.title).to eq(options[:list])
        expect(note.body.list.list_items.first.text.text).to eq("Buy milk")
        expect(note.body.list.list_items.first.child_list_items.first.text.text).to eq("Chives")
      end

      result = service.sync_from_primary(primary_service)

      expect(result["items_synced"]).to eq(1)
    end

    it "deletes the Keep note when the primary list is empty" do
      allow(primary_service).to receive(:items_to_sync).with(tags: [service.friendly_name]).and_return([])

      expect(keep_service).to receive(:delete_note).with("notes/existing")

      result = service.sync_from_primary(primary_service)

      expect(result["items_synced"]).to eq(0)
    end
  end

  describe "#sync_to_primary" do
    let(:root_item) do
      GoogleKeep::Item.new(
        keep_item: {
          note: Google::Apis::KeepV1::Note.new(title: options[:list], update_time: Time.current),
          note_title: options[:list],
          item: Google::Apis::KeepV1::ListItem.new(
            text: Google::Apis::KeepV1::TextContent.new(text: "Buy milk"),
            checked: false
          ),
          path: [0]
        },
        options:
      ).tap(&:read_original)
    end
    let(:primary_service) do
      instance_double(
        "Primary::Service",
        friendly_name: "Omnifocus",
        items_to_sync: [],
        add_item: nil,
        update_item: nil,
        item_class: nil
      )
    end

    before do
      allow(service).to receive(:should_sync?).and_return(true)
      allow(service).to receive(:items_to_sync).and_return([root_item])
    end

    it "sends Keep items to the primary service" do
      expect(primary_service).to receive(:add_item).with(root_item)

      result = service.sync_to_primary(primary_service)

      expect(result["items_synced"]).to eq(1)
    end
  end
end
