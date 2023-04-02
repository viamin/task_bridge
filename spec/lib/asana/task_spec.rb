# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Asana::Task" do
  let(:asana_task) { Asana::Task.new(asana_task: asana_task_json, options:) }
  let(:asana_task_json) { JSON.parse(File.read(File.expand_path(File.join(__dir__, "..", "..", "fixtures", "asana_task.json")))) }
  let(:options) { { tags: [] } }

  describe "new" do
    it "parses out the sync_id from notes" do
      expect(asana_task.sync_id).to eq("jU466dYHf2o")
    end
  end
end
