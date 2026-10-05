# frozen_string_literal: true

require "rails_helper"

# Full-list source coverage for deletion detection (#220): Google Keep's
# note read is the complete item universe, so absence after a successful
# read is a real deletion — but a missing note must never look like one.
RSpec.describe "Google Keep deletion detection" do
  include_context "full_options"

  let(:options) { full_options.merge(list: "My Tasks", service_name: "GoogleKeep", pretend: false, quiet: true) }
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}, last_synced: Time.current - 1.day) }
  let(:keep_service) { instance_double(Google::Apis::KeepV1::KeepService, "authorization=": true) }
  let(:service) { described_service.new(options:, keep_service:, authorization: {}) }
  let(:described_service) { GoogleKeep::Service }

  def keep_note_with(*keep_ids)
    list_items = keep_ids.map do |keep_id|
      Google::Apis::KeepV1::ListItem.new(
        text: Google::Apis::KeepV1::TextContent.new(
          text: GoogleKeep::Item.text_with_external_id("Item #{keep_id}", keep_id)
        ),
        checked: false
      )
    end
    Google::Apis::KeepV1::Note.new(
      name: "notes/123",
      title: options[:list],
      body: Google::Apis::KeepV1::Section.new(
        list: Google::Apis::KeepV1::ListContent.new(list_items:)
      )
    )
  end

  def stub_notes(note)
    response = double("notes_response", notes: [note].compact, next_page_token: nil)
    allow(keep_service).to receive(:list_notes).with(page_size: 100).and_return(response)
  end

  def persisted_keep_item(external_id, attributes = {})
    GoogleKeep::Item.create!(
      {
        external_id:,
        title: "Item #{external_id}",
        source_service_name: service.service_name,
        source_metadata: { "stable_external_id_embedded" => true },
        keep_item: {
          item: Google::Apis::KeepV1::ListItem.new(
            text: Google::Apis::KeepV1::TextContent.new(
              text: GoogleKeep::Item.text_with_external_id("Item #{external_id}", external_id)
            ),
            checked: false
          ),
          note: Google::Apis::KeepV1::Note.new(title: options[:list], update_time: Time.current),
          note_title: options[:list],
          path: [0]
        },
        options:
      }.merge(attributes)
    )
  end

  def tombstones
    OutboxEntry.where(record_kind: "observation", event_type: "deleted")
  end

  describe "a successful note read" do
    it "persists embedded-id provenance so a later absence is detected" do
      stub_notes(keep_note_with("keep-1"))

      service.items_to_sync

      observed_item = GoogleKeep::Item.find_by!(external_id: "keep-1")
      expect(observed_item.source_metadata).to include("stable_external_id_embedded" => true)

      stub_notes(keep_note_with)
      described_service.new(options:, keep_service:, authorization: {}).items_to_sync

      expect(tombstones.pluck(:external_id)).to contain_exactly("keep-1")
    end

    it "enqueues a source_deleted tombstone for the vanished embedded id" do
      stub_notes(keep_note_with("keep-1"))
      vanished = persisted_keep_item("keep-2")
      persisted_keep_item("keep-1")

      service.items_to_sync

      expect(tombstones.count).to eq(1)
      entry = tombstones.first
      expect(entry.external_id).to eq("keep-2")
      expect(entry.payload["disappearance_state"]).to eq("source_deleted")
      expect(entry.payload["is_deleted"]).to be(true)
      expect(entry.payload["provenance"]).to match(
        hash_including("detected_by" => "missing_from_full_list", "confidence" => "high")
      )
      expect(vanished.reload.disappearance_observation).to match(hash_including("state" => "source_deleted"))
    end

    it "keeps the local row rather than deleting it" do
      stub_notes(keep_note_with("keep-1"))
      vanished = persisted_keep_item("keep-2")

      service.items_to_sync

      expect(GoogleKeep::Item.exists?(vanished.id)).to be(true)
    end

    it "does not tombstone items without an embedded stable id" do
      stub_notes(keep_note_with("keep-1"))
      persisted_keep_item("keep-foreign", source_metadata: {})

      service.items_to_sync

      expect(tombstones.count).to eq(0)
    end

    it "is idempotent across repeated fetches" do
      stub_notes(keep_note_with("keep-1"))
      persisted_keep_item("keep-2")

      service.items_to_sync
      fresh_service = described_service.new(options:, keep_service:, authorization: {})
      fresh_service.items_to_sync

      expect(tombstones.count).to eq(1)
    end
  end

  describe "a missing note" do
    it "emits no tombstones even though the fetch returns nothing" do
      stub_notes(nil)
      persisted_keep_item("keep-1")
      persisted_keep_item("keep-2")

      expect(service.items_to_sync).to eq([])
      expect(tombstones.count).to eq(0)
    end
  end

  describe "suppression guards" do
    it "emits nothing during a partial (only_modified_dates) fetch" do
      stub_notes(keep_note_with("keep-1"))
      persisted_keep_item("keep-2")

      service.items_to_sync(only_modified_dates: true)

      expect(tombstones.count).to eq(0)
    end

    it "emits nothing in pretend mode" do
      stub_notes(keep_note_with("keep-1"))
      persisted_keep_item("keep-2")
      pretend_service = described_service.new(
        options: options.merge(pretend: true), keep_service:, authorization: {}
      )

      pretend_service.items_to_sync

      expect(tombstones.count).to eq(0)
    end
  end
end
