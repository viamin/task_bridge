# frozen_string_literal: true

# == Schema Information
#
# Table name: sync_items
#
#  id                 :integer          not null, primary key
#  completed          :boolean
#  completed_at       :datetime
#  completed_on       :datetime
#  due_at             :datetime
#  due_date           :datetime
#  flagged            :boolean
#  item_type          :string
#  last_modified      :datetime
#  notes              :string
#  start_at           :datetime
#  start_date         :datetime
#  status             :string
#  title              :string
#  type               :string
#  url                :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  external_id        :string
#  parent_item_id     :integer
#  sync_collection_id :integer
#
# Indexes
#
#  index_sync_items_on_parent_item_id      (parent_item_id)
#  index_sync_items_on_sync_collection_id  (sync_collection_id)
#
# Foreign Keys
#
#  parent_item_id      (parent_item_id => sync_items.id)
#  sync_collection_id  (sync_collection_id => sync_collections.id)
#
require "rails_helper"

RSpec.describe GoogleTasks::Task do
  let(:google_task) { GoogleTasks::Task.new(google_task: google_task_json, google_tasklist: tasklist) }
  let(:tasklist) { { "id" => "task-list-id", "title" => "TaskBridge" } }
  let(:google_task_json) do
    {
      "id" => id,
      "title" => title,
      "self_link" => url,
      "notes" => notes,
      "status" => status,
      "completed" => completed_at,
      "parent" => parent_id,
      "web_view_link" => web_view_link
    }.compact
  end
  let(:id) { Faker::Number.number(digits: 10) }
  let(:title) { Faker::Lorem.sentence }
  let(:url) { Faker::Internet.url }
  let(:notes) { "notes\n\nomnifocus_id: jU466dYHf2o" }
  let(:status) { "needsAction" }
  let(:completed_at) { nil }
  let(:parent_id) { nil }
  let(:web_view_link) { "https://tasks.google.com/embed/list/~default" }

  it_behaves_like "sync_item" do
    let(:item) { google_task }
  end

  it_behaves_like "normalized_snapshot" do
    let(:item) { google_task }
  end

  describe "new" do
    it "parses out the omnifocus_id from notes" do
      expect(google_task.omnifocus_id).to eq("jU466dYHf2o")
    end
  end

  describe "#normalized_metadata" do
    before { google_task.read_original }

    it "carries the tasklist identity, parent, and web link under metadata" do
      expect(google_task.normalized_metadata).to eq(
        list: "TaskBridge",
        list_id: "task-list-id",
        web_view_link:
      )
    end

    it "carries the parent task id when the payload provides one" do
      subtask = GoogleTasks::Task.new(
        google_task: google_task_json.merge("parent" => "parent-task-id"),
        google_tasklist: tasklist
      )
      subtask.read_original

      expect(subtask.normalized_metadata).to include(parent: "parent-task-id")
    end
  end

  describe "#normalized_snapshot" do
    context "with a completed task" do
      let(:status) { "completed" }
      let(:completed_at) { "2024-04-03T10:00:00.000Z" }

      it "publishes the completion timestamp and enriched metadata" do
        google_task.read_original
        snapshot = google_task.normalized_snapshot

        expect(snapshot[:completed]).to be(true)
        expect(snapshot[:completed_at]).to eq(Chronic.parse("2024-04-03T10:00:00.000Z"))
        expect(snapshot[:metadata]).to eq(google_task.normalized_metadata)
      end
    end
  end

  describe ".from_external" do
    let(:external_task) do
      instance_double(
        Reclaim::Task,
        completed?: true,
        completed_at: Time.zone.parse("2024-04-03 10:00:00 UTC"),
        due_date: Time.zone.parse("2024-04-04 10:00:00 UTC"),
        sync_notes: "sync notes", notes_content: "sync notes",
        title: "Review PR"
      )
    end

    it "uses the polymorphic completion predicate for the exported status" do
      allow(Reclaim::Task).to receive(:title_addon).with(external_task, skip: false).and_return(" (addon)")

      expect(described_class.from_external(external_task, skip_reclaim: false)).to include(
        completed: "2024-04-03T00:00:00+00:00",
        due: "2024-04-04T00:00:00+00:00",
        notes: "sync notes",
        status: "completed",
        title: "Review PR (addon)"
      )
    end

    it "handles skip_reclaim: true without raising" do
      allow(Reclaim::Task).to receive(:title_addon).with(external_task, skip: true).and_return(nil)

      result = described_class.from_external(external_task, skip_reclaim: true)
      expect(result[:title]).to eq("Review PR")
    end
  end
end
