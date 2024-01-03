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
