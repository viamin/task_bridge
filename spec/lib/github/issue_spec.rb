# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Github::Issue" do
  let(:service) { Github::Service.new }
  let(:issue) { Github::Issue.new(github_issue: properties, options:) }
  let(:options) { { tags: [] } }
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

  it "is marked open" do
    expect(issue).to be_open
  end

  context "when status is closed" do
    let(:status) { "closed" }

    it "is marked completed" do
      expect(issue).to be_completed
    end
  end

  describe "#sync_notes" do
    let(:notes) { "notes\n\nsync_id: #{id}\n" }

    it "adds a sync_url to the notes" do
      expect(issue.notes).to eq("body")
      expect(issue.sync_url).to eq("#{repo_url}/issues/#{number}")
      expect(issue.sync_notes).to eq("body\n\nurl: #{repo_url}/issues/#{number}\n")
    end
  end
end
