# frozen_string_literal: true

require "rails_helper"

RSpec.describe "NoteParser" do
  let(:note_parser_class) { Class.new { include NoteParser }.new }
  let(:id) { 12_345 }
  let(:url) { Faker::Internet.url }
  let(:previous_notes) { "notes" }

  describe "#parsed_notes" do
    let(:notes) { "#{previous_notes}\n\nomnifocus_id: #{id}\nomnifocus_url: #{url}\n" }

    it "returns a Hash" do
      expect(note_parser_class.parsed_notes(keys: %w[omnifocus_id omnifocus_url], notes:)).to be_a(Hash)
    end

    it "parses out the values for the given list of keys" do
      parsed_data = note_parser_class.parsed_notes(keys: %w[omnifocus_id omnifocus_url], notes:)
      expect(parsed_data["omnifocus_id"]).to eq(id.to_s)
      expect(parsed_data["omnifocus_url"]).to eq(url)
      expect(parsed_data["notes"]).to eq(previous_notes)
    end

    it "works when there's no newline at the end of the notes" do
      parsed_data = note_parser_class.parsed_notes(keys: %w[omnifocus_id omnifocus_url], notes: notes.strip)
      expect(parsed_data["omnifocus_id"]).to eq(id.to_s)
      expect(parsed_data["omnifocus_url"]).to eq(url)
      expect(parsed_data["notes"]).to eq(previous_notes)
    end

    it "works when the keys are processed in a different order" do
      parsed_data = note_parser_class.parsed_notes(keys: %w[omnifocus_url omnifocus_id], notes:)
      expect(parsed_data["omnifocus_id"]).to eq(id.to_s)
      expect(parsed_data["omnifocus_url"]).to eq(url)
      expect(parsed_data["notes"]).to eq(previous_notes)
    end

    it "works when there aren't extra newlines" do
      parsed_data = note_parser_class.parsed_notes(keys: %w[omnifocus_url omnifocus_id], notes: notes.squish)
      expect(parsed_data["omnifocus_id"]).to eq(id.to_s)
      expect(parsed_data["omnifocus_url"]).to eq(url)
      expect(parsed_data["notes"]).to eq(previous_notes)
    end

    it "works when there aren't any notes or ids" do
      parsed_data = note_parser_class.parsed_notes(keys: %w[omnifocus_url omnifocus_id], notes: "")
      expect(parsed_data["omnifocus_id"]).to be_nil
      expect(parsed_data["omnifocus_url"]).to be_nil
      expect(parsed_data["notes"]).to eq("")
    end

    it "works when there aren't any notes" do
      parsed_data = note_parser_class.parsed_notes(keys: %w[omnifocus_url omnifocus_id], notes: "omnifocus_id: #{id}\nomnifocus_url: #{url}\n")
      expect(parsed_data["omnifocus_id"]).to eq(id.to_s)
      expect(parsed_data["omnifocus_url"]).to eq(url)
      expect(parsed_data["notes"]).to eq("")
    end

    it "returns notes when there aren't any keys" do
      parsed_data = note_parser_class.parsed_notes(notes:)
      expect(parsed_data["omnifocus_id"]).to be_nil
      expect(parsed_data["omnifocus_url"]).to be_nil
      expect(parsed_data["notes"]).to eq(notes.strip)
    end

    context "with duplicate keys" do
      let(:notes) { "#{previous_notes}\nasana_url: https://app.asana.com/0/1205790342215875/1205790342215879\n\nasana_id: 1205790342215879\nasana_url: https://app.asana.com/0/1205790342215875/1205790342215879" }

      it "removes the duplicates" do
        parsed_data = note_parser_class.parsed_notes(keys: %w[asana_url asana_id], notes:)
        expect(parsed_data["notes"]).to eq(previous_notes.strip)
      end
    end
  end

  describe "#notes_with_values" do
    let(:notes) { "notes" }

    it "adds the values to the notes" do
      expect(note_parser_class.notes_with_values(notes, {omnifocus_id: id, omnifocus_url: url})).to eq("notes\n\nomnifocus_id: #{id}\nomnifocus_url: #{url}")
    end

    context "when notes are blank" do
      let(:notes) { "" }

      it "adds the values to the notes and strips whitespace" do
        expect(note_parser_class.notes_with_values(notes, {omnifocus_id: id, omnifocus_url: url})).to eq("omnifocus_id: #{id}\nomnifocus_url: #{url}")
      end
    end

    context "when notes are nil" do
      let(:notes) { nil }

      it "handles nil notes gracefully" do
        expect(note_parser_class.notes_with_values(notes, {omnifocus_id: id})).to eq("omnifocus_id: #{id}")
      end
    end

    context "when notes already contain the same key" do
      let(:old_id) { 99_999 }
      let(:notes) { "Some task notes\n\nasana_id: #{old_id}" }

      it "replaces the existing key value instead of duplicating it" do
        result = note_parser_class.notes_with_values(notes, {asana_id: id})
        expect(result).to eq("Some task notes\n\nasana_id: #{id}")
        expect(result.scan("asana_id:").count).to eq(1)
      end
    end

    context "when notes contain multiple duplicate keys" do
      let(:notes) { "Task notes\n\nasana_id: 111\nasana_url: https://old.url\n\nasana_id: 222\nasana_url: https://another.url" }

      it "removes all existing occurrences and adds the new value once" do
        result = note_parser_class.notes_with_values(notes, {asana_id: id, asana_url: url})
        expect(result.scan("asana_id:").count).to eq(1)
        expect(result.scan("asana_url:").count).to eq(1)
        expect(result).to include("asana_id: #{id}")
        expect(result).to include("asana_url: #{url}")
        expect(result).not_to include("111")
        expect(result).not_to include("222")
      end
    end
  end
end
