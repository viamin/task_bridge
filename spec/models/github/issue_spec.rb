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

RSpec.describe "Github::Issue" do
  let(:service) { Github::Service.new }
  let(:issue) { Github::Issue.new(github_issue: properties) }
  let(:id) { Faker::Number.number(digits: 10) }
  let(:number) { Faker::Number.number(digits: 3) }
  let(:title) { Faker::Lorem.sentence }
  let(:repo_url) { "https://api.github.com/repos/viamin/task_bridge" }
  let(:url) { "#{repo_url}/issues/#{number}" }
  let(:body) { "body" }
  let(:status) { "open" }
  let(:labels) { [] }
  let(:start_date) { "Today" }
  let(:due_date) { "Tomorrow" }
  let(:properties) do
    {
      "id" => id,
      "number" => number,
      "title" => title,
      "html_url" => url,
      "repository_url" => repo_url,
      "body" => body,
      "state" => status,
      "labels" => labels
    }.compact
  end

  it_behaves_like "sync_item" do
    let(:item) { issue }
  end

  it "is marked open" do
    expect(issue).to be_open
  end

  context "when status is closed" do
    let(:status) { "closed" }

    it "is marked completed" do
      expect(issue).to be_completed
    end
  end
end
