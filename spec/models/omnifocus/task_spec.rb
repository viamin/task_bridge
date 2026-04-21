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

RSpec.describe "Omnifocus::Task" do
  let(:service) { Omnifocus::Service.new }
  let(:task) { Omnifocus::Task.new(omnifocus_task: properties) }
  let(:id) { SecureRandom.alphanumeric(11) }
  let(:name) { Faker::Lorem.sentence }
  let(:notes) { "notes" }
  let(:completed) { [true, false].sample }
  let(:containing_project) { "Folder:Project" }
  let(:tasks) { [] }
  let(:tags) { [] }
  let(:properties) do
    OpenStruct.new({
      id_: id,
      name:,
      completed:,
      note: notes,
      containing_project:,
      tags: tags.map { |tag| OpenStruct.new({name: tag}) },
      tasks:
    }.compact)
  end

  before do
    task.read_original
  end

  it_behaves_like "sync_item" do
    let(:item) { task }
  end

  context "with time-related tags" do
    context "with a relative date tag" do
      let(:tags) { ["This Week"] }

      it "sets a due date to this week" do
        expect(task.due_date).to eq(Chronic.parse("the end of this week"))
      end
    end

    context "with a month tag" do
      let(:tags) { ["12 - December"] }

      it "sets a due date in December" do
        parsed_date = Chronic.parse("12 - December")
        # If the date is in the past, the code adds 1 year
        expected_date = (parsed_date < Time.now) ? parsed_date + 1.year : parsed_date
        expect(task.due_date).to eq(expected_date)
      end

      context "when the date is in the past" do
        let(:tags) { ["01 - January"] }

        it "sets a due date in the future" do
          expect(task.due_date).to be > Time.now
        end
      end
    end

    context "with a weekday tag" do
      let(:tags) { ["Tuesday"] }

      it "sets a due date of next Tuesday" do
        expect(task.due_date).to eq(Chronic.parse("Next Tuesday"))
      end
    end
  end

  context "when tags are nil" do
    let(:tags) { [] }
    let(:task_with_nil_tags) { Omnifocus::Task.new(omnifocus_task: properties) }

    before do
      task_with_nil_tags.instance_variable_set(:@tags, nil)
      allow(task_with_nil_tags).to receive(:options).and_return({uses_personal_tags: true, personal_tags: ["Personal"]})
    end

    it "personal? returns false without raising" do
      expect { task_with_nil_tags.personal? }.not_to raise_error
      expect(task_with_nil_tags.personal?).to be false
    end
  end

  context "when sub_items is nil" do
    let(:tasks) { nil }
    let(:nil_sub_task) { Omnifocus::Task.new(omnifocus_task: OpenStruct.new({id_: "sub_nil", name: "SubNil", completed: false, note: "", tasks: nil})) }

    it "sub_item_count defaults to 0 instead of nil" do
      nil_sub_task.read_original
      expect(nil_sub_task.sub_item_count).to eq(0)
    end
  end

  context "when a sub_item reference goes stale while reading the id" do
    let(:stale_id) do
      double("StaleSubItemId").tap do |id|
        allow(id).to receive(:get).and_raise(make_stale_reference_error(command: "id_.get"))
      end
    end
    let(:stale_sub_item) { OpenStruct.new(id_: stale_id) }
    let(:valid_sub_item) do
      OpenStruct.new(
        id_: "sub_ok",
        name: "Sub task",
        completed: false,
        note: "",
        containing_project: "",
        tags: [],
        tasks: [],
        modification_date: Time.current
      )
    end
    let(:tasks) { [stale_sub_item, valid_sub_item] }

    it "skips the stale sub_item" do
      expect(task.sub_items.map(&:external_id)).to eq(["sub_ok"])
      expect(task.sub_item_count).to eq(1)
    end
  end

  context "with metadata-only reads" do
    let(:metadata_task_data) do
      double(
        "OmnifocusMetadataTask",
        id_: "metadata-task",
        name: "Metadata task",
        completed: false,
        completion_date: nil,
        modification_date: Time.current,
        note: ""
      )
    end
    let(:metadata_task) { Omnifocus::Task.new(omnifocus_task: metadata_task_data) }

    it "does not read project, tags, due date, or sub-items" do
      metadata_task.read_original(only_modified_dates: true)

      expect(metadata_task.external_id).to eq("metadata-task")
      expect(metadata_task.title).to eq("Metadata task")
      expect(metadata_task.sub_items).to eq([])
      expect(metadata_task.sub_item_count).to eq(0)
    end
  end
end
