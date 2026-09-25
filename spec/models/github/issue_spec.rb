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
  let(:author) { { "login" => "viamin" } }
  let(:assignee) { nil }
  let(:assignees) { [] }
  let(:milestone) { nil }
  let(:comments) { 3 }
  let(:closed_at) { nil }
  let(:properties) do
    {
      "id" => id,
      "number" => number,
      "title" => title,
      "html_url" => url,
      "repository_url" => repo_url,
      "body" => body,
      "state" => status,
      "labels" => labels,
      "user" => author,
      "assignee" => assignee,
      "assignees" => assignees,
      "milestone" => milestone,
      "comments" => comments,
      "closed_at" => closed_at
    }.compact
  end

  before do
    issue.read_original
  end

  it_behaves_like "sync_item" do
    let(:item) { issue }
  end

  it_behaves_like "normalized_snapshot" do
    let(:item) { issue }
  end

  describe "#normalized_metadata" do
    it "carries the GitHub-specific facts under metadata" do
      expect(issue.normalized_metadata).to eq(
        number:,
        pull_request: false,
        repository: "viamin/task_bridge",
        author: "viamin",
        assignees: [],
        comments_count: 3
      )
    end

    it "carries assignee, milestone, and PR draft details when present" do
      issue.github_issue.merge!(
        "assignee" => { "login" => "octocat" },
        "assignees" => [{ "login" => "octocat" }, { "login" => "monalisa" }],
        "milestone" => { "title" => "v1.0" },
        "draft" => true,
        "pull_request" => { "diff_url" => "#{repo_url}/pulls/#{number}.diff" }
      )
      issue.read_original

      expect(issue.normalized_metadata).to include(
        assignees: %w[octocat monalisa],
        milestone: "v1.0",
        draft: true,
        pull_request: true
      )
      expect(issue.assignee).to eq("octocat")
    end
  end

  describe "#normalized_snapshot" do
    it "publishes the enriched fields for a closed issue" do
      issue.github_issue.merge!("state" => "closed", "closed_at" => "2024-04-05T10:00:00Z")
      issue.read_original
      snapshot = issue.normalized_snapshot

      expect(snapshot[:completed]).to be(true)
      expect(snapshot[:completed_at]).to eq(Chronic.parse("2024-04-05T10:00:00Z"))
      expect(snapshot[:metadata]).to eq(issue.normalized_metadata)
    end
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

  context "when repository_url is nil" do
    let(:repo_url) { nil }

    it "uses unknown as the short repo name instead of raising" do
      issue.read_original
      expect(issue.project).to eq("unknown")
    end
  end

  context "when labels is nil" do
    let(:properties) do
      {
        "id" => id,
        "number" => number,
        "title" => title,
        "html_url" => url,
        "repository_url" => repo_url,
        "body" => body,
        "state" => status,
        "labels" => nil
      }
    end

    it "does not raise during read_original" do
      expect { issue.read_original }.not_to raise_error
    end
  end
end
