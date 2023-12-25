# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Github::Issue", :full_options do
  let(:service) { Github::Service.new }
  let(:issue) { Github::Issue.new(github_issue: properties, options:) }
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
