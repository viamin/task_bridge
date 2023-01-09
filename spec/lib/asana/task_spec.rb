# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Asana::Task" do
  let(:asana_task) { Asana::Task.new(asana_task_json, options) }
  let(:asana_task_json) { JSON.parse(File.read(File.expand_path(File.join(__dir__, "..", "..", "fixtures", "asana_task.json")))) }
  let(:options) { { tags: [] } }

  describe "new" do
    it "parses out the sync_id from notes" do
      expect(asana_task.sync_id).to eq("jU466dYHf2o")
    end
  end

  describe "#sync_notes" do
    before { allow(asana_task).to receive(:notes).and_return("notes") }

    it "adds a sync_id to the notes" do
      expect(asana_task.notes).to eq("notes")
      expect(asana_task.sync_id).to eq("jU466dYHf2o")
      expect(asana_task.sync_notes).to eq("notes\n\nsync_id: jU466dYHf2o\n")
    end
  end
end
