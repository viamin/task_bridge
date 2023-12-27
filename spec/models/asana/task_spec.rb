# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Asana::Task" do
  let(:asana_task) { Asana::Task.new(asana_task: asana_task_json) }
  let(:asana_task_json) { JSON.parse(File.read(File.expand_path(Rails.root.join("spec", "fixtures", "asana_task.json")))) }

  it_behaves_like "sync_item" do
    let(:item) { asana_task }
  end

  describe "new" do
    it "parses out the omnifocus_id from notes" do
      expect(asana_task.omnifocus_id).to eq("jU466dYHf2o")
    end
  end
end
