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

RSpec.describe "Reclaim::Task" do
  let(:service) { Reclaim::Service.new }
  let(:task) { Reclaim::Task.new(reclaim_task: properties) }
  let(:id) { Faker::Number.number(digits: 7) }
  let(:title) { Faker::Lorem.sentence }
  let(:notes) { "notes" }
  let(:start_date) { "Today" }
  let(:due_date) { "Tomorrow" }
  let(:event_category) { %w[WORK PERSONAL].sample }
  let(:properties) do
    {
      "id" => id,
      "title" => title,
      "due" => due_date,
      "snoozeUntil" => start_date,
      "notes" => notes,
      "eventCategory" => event_category
    }.compact
  end

  before do
    task.read_original
  end

  it_behaves_like "sync_item" do
    let(:item) { task }
  end

  it "parses the due_date" do
    expect(task.due_date).to be_instance_of(ActiveSupport::TimeWithZone)
  end

  it "parses the start_date" do
    expect(task.start_date).to be_instance_of(ActiveSupport::TimeWithZone)
  end

  context "when eventCatgory is personal" do
    let(:event_category) { Reclaim::Task::PERSONAL }

    it "is personal" do
      expect(task).to be_personal
    end
  end
end
