# frozen_string_literal: true

require "spec_helper"

RSpec.describe "NoteParser" do
  let(:note_parser_class) { Class.new { include NoteParser }.new }
  let(:id) { 12_345 }
  let(:url) { Faker::Internet.url }

  describe "#parsed_notes" do
    let(:notes) { "notes\n\nsync_id: #{id}\nurl: #{url}\n" }

    it "parses out the values for the given list of keys" do
      parsed_id, parsed_url, parsed_notes = note_parser_class.parsed_notes(keys: %w[sync_id url], notes:)
      expect(parsed_id).to eq(id.to_s)
      expect(parsed_url).to eq(url)
      expect(parsed_notes).to eq("notes")
    end

    it "works when there's no newline at the end of the notes" do
      parsed_id, parsed_url, parsed_notes = note_parser_class.parsed_notes(keys: %w[sync_id url], notes: notes.strip)
      expect(parsed_id).to eq(id.to_s)
      expect(parsed_url).to eq(url)
      expect(parsed_notes).to eq("notes")
    end

    it "works when the keys are processed in a different order" do
      parsed_url, parsed_id, parsed_notes = note_parser_class.parsed_notes(keys: %w[url sync_id], notes:)
      expect(parsed_id).to eq(id.to_s)
      expect(parsed_url).to eq(url)
      expect(parsed_notes).to eq("notes")
    end
  end

  describe "#notes_with_values" do
    let(:notes) { "notes" }

    it "adds the values to the notes" do
      expect(note_parser_class.notes_with_values(notes, { sync_id: id, url: })).to eq("notes\n\nsync_id: #{id}\nurl: #{url}\n")
    end
  end
end
