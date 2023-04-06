# frozen_string_literal: true

require "spec_helper"

RSpec.describe GoogleTasks::Task, :full_options do
  let(:google_task) { GoogleTasks::Task.new(google_task: google_task_json, options:) }
  let(:google_task_json) do
    {
      "id" => id,
      "title" => title,
      "self_link" => url,
      "notes" => notes
    }
  end
  let(:id) { Faker::Number.number(digits: 10) }
  let(:title) { Faker::Lorem.sentence }
  let(:url) { Faker::Internet.url }
  let(:notes) { "notes\n\nomnifocus_id: jU466dYHf2o" }

  it_behaves_like "sync_item" do
    let(:item) { google_task }
  end

  describe "new" do
    it "parses out the omnifocus_id from notes" do
      expect(google_task.sync_id("Omnifocus")).to eq("jU466dYHf2o")
    end
  end
end
