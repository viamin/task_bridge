# frozen_string_literal: true

require "spec_helper"

RSpec.describe "NoteParser" do
  let(:note_parser_class) { Class.new { include NoteParser }.new }
  let(:id) { 12_345 }
  let(:url) { Faker::Internet.url }
  let(:previous_notes) { "notes" }

  describe "#parsed_notes" do
    let(:notes) { "#{previous_notes}\n\nsync_id: #{id}\nurl: #{url}\n" }

    it "returns a Hash" do
      expect(note_parser_class.parsed_notes(keys: %w[sync_id url], notes:)).to be_a(Hash)
    end

    it "parses out the values for the given list of keys" do
      parsed_data = note_parser_class.parsed_notes(keys: %w[sync_id url], notes:)
      expect(parsed_data["sync_id"]).to eq(id.to_s)
      expect(parsed_data["url"]).to eq(url)
      expect(parsed_data["notes"]).to eq(previous_notes)
    end

    it "works when there's no newline at the end of the notes" do
      parsed_data = note_parser_class.parsed_notes(keys: %w[sync_id url], notes: notes.strip)
      expect(parsed_data["sync_id"]).to eq(id.to_s)
      expect(parsed_data["url"]).to eq(url)
      expect(parsed_data["notes"]).to eq(previous_notes)
    end

    it "works when the keys are processed in a different order" do
      parsed_data = note_parser_class.parsed_notes(keys: %w[url sync_id], notes:)
      expect(parsed_data["sync_id"]).to eq(id.to_s)
      expect(parsed_data["url"]).to eq(url)
      expect(parsed_data["notes"]).to eq(previous_notes)
    end

    it "works when there aren't extra newlines" do
      parsed_data = note_parser_class.parsed_notes(keys: %w[url sync_id], notes: notes.squish)
      expect(parsed_data["sync_id"]).to eq(id.to_s)
      expect(parsed_data["url"]).to eq(url)
      expect(parsed_data["notes"]).to eq(previous_notes)
    end

    it "works when there aren't any notes" do
      parsed_data = note_parser_class.parsed_notes(keys: %w[url sync_id], notes: "")
      expect(parsed_data["sync_id"]).to be_nil
      expect(parsed_data["url"]).to be_nil
      expect(parsed_data["notes"]).to eq("")
    end

    it "returns notes when there aren't any keys" do
      parsed_data = note_parser_class.parsed_notes(notes:)
      expect(parsed_data["sync_id"]).to be_nil
      expect(parsed_data["url"]).to be_nil
      expect(parsed_data["notes"]).to eq(notes.strip)
    end
  end

  describe "#notes_with_values" do
    let(:notes) { "notes" }

    it "adds the values to the notes" do
      expect(note_parser_class.notes_with_values(notes, { sync_id: id, url: })).to eq("notes\n\nsync_id: #{id}\nurl: #{url}\n")
    end
  end
end
