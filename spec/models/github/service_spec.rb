# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Github::Service" do
  let(:min_sync_interval) { 60.minutes.to_i }
  let(:service) { Github::Service.new }
  let(:last_sync) { Time.now - min_sync_interval }
  let(:httparty_success_mock) { OpenStruct.new(success?: true, body: { data: { task: external_task.to_json } }.to_json) }
  let(:access_token) { { "access_token" => "token" } }

  before do
    allow_any_instance_of(StructuredLogger).to receive(:sync_data_for).and_return({})
    allow_any_instance_of(StructuredLogger).to receive(:last_synced).and_return(last_sync)
    allow_any_instance_of(Github::Authentication).to receive(:authenticate!).and_return(access_token)
  end

  describe "#sync_to_primary" do
    context "with omnifocus" do
      let(:primary_service) { Omnifocus::Service.new }

      it "responds to #sync_to_primary" do
        expect(service).to be_respond_to(:sync_to_primary)
      end
    end
  end

  describe "#items_to_sync" do
    subject { service.items_to_sync }

    let(:external_issue) do
      {
        "id" => 123,
        "number" => 5,
        "title" => "Ship Rails migration",
        "state" => "open",
        "body" => "notes",
        "html_url" => "https://github.com/org/repo/issues/5",
        "updated_at" => "2024-04-01T12:00:00Z",
        "repository_url" => "https://api.github.com/repos/org/repo",
        "labels" => []
      }
    end

    before do
      allow(service).to receive(:sync_repositories).with(no_args).and_return(["org/repo"])
      allow(service).to receive(:sync_repositories).with(with_url: true).and_return(["https://api.github.com/repos/org/repo"])
      allow(service).to receive(:list_issues).and_return([external_issue])
      allow(service).to receive(:list_assigned).and_return([external_issue])
      allow(service).to receive(:publish_activity_for)
    end

    it "loads external_id from the shared external attribute map" do
      expect(subject.map(&:external_id)).to eq([external_issue["id"].to_s])
    end
  end

  describe "#list_issues" do
    let(:response) { instance_double(HTTParty::Response, success?: true, body: [].to_json) }
    let(:captured_query) { {} }

    before do
      allow(HTTParty).to receive(:get) do |_url, options|
        captured_query.replace(options.fetch(:query))
        response
      end
    end

    it "uses the last successful sync time when present" do
      sync_time = Time.zone.parse("2024-04-03 12:00:00 UTC")
      allow(service).to receive(:last_successful_sync_at).and_return(sync_time)

      service.send(:list_issues, "org/repo", [])

      expect(captured_query[:since]).to eq(sync_time.iso8601)
    end

    it "falls back to the initial two-day window when no sync state exists" do
      fallback_time = Time.zone.parse("2024-04-03 12:00:00 UTC")
      allow(service).to receive(:last_successful_sync_at).and_return(nil)
      allow(Chronic).to receive(:parse).with("2 days ago").and_return(fallback_time)

      service.send(:list_issues, "org/repo", [])

      expect(captured_query[:since]).to eq(fallback_time.iso8601)
    end

    it "raises a readable error message when the issues request fails" do
      failed_response = instance_double(HTTParty::Response, code: 500, success?: false, body: "boom")
      allow(HTTParty).to receive(:get).and_return(failed_response)

      expect do
        service.send(:list_issues, "org/repo", [])
      end.to raise_error(
        RuntimeError,
        "Error loading Github issues - check repository name and access (response code: 500)"
      )
    end
  end

  describe "GitHub activity retrieval" do
    let(:activity_response) do
      instance_double(HTTParty::Response, success?: true, body: [].to_json, headers: {})
    end

    before { allow(HTTParty).to receive(:get).and_return(activity_response) }

    it "uses a bounded latest-page request for timeline activity" do
      service.send(:timeline_events, "repository_url" => "https://api.github.com/repos/org/repo", "number" => 5)

      expect(HTTParty).to have_received(:get).with(
        "https://api.github.com/repos/org/repo/issues/5/timeline",
        hash_including(query: { per_page: "100" })
      )
    end

    it "follows previous pages until activity predates the cursor" do
      first_page = instance_double(
        HTTParty::Response,
        success?: true,
        body: [].to_json,
        headers: { "link" => '<https://api.github.com/page/3>; rel="last"' }
      )
      last_page = instance_double(
        HTTParty::Response,
        success?: true,
        body: [{ "id" => "3", "created_at" => "2026-10-05T12:00:00Z" }].to_json,
        headers: { "link" => '<https://api.github.com/page/2>; rel="prev"' }
      )
      middle_page = instance_double(
        HTTParty::Response,
        success?: true,
        body: [{ "id" => "2", "created_at" => "2026-10-05T11:00:00Z" }].to_json,
        headers: { "link" => '<https://api.github.com/page/1>; rel="prev"' }
      )
      oldest_page = instance_double(
        HTTParty::Response,
        success?: true,
        body: [{ "id" => "1", "created_at" => "2026-10-05T09:00:00Z" }].to_json,
        headers: {}
      )
      allow(service).to receive(:activity_since).and_return(Time.zone.parse("2026-10-05T10:00:00Z"))
      allow(HTTParty).to receive(:get).and_return(first_page, last_page, middle_page, oldest_page)

      events = service.send(:timeline_events, "repository_url" => "https://api.github.com/repos/org/repo", "number" => 5)

      expect(HTTParty).to have_received(:get).with("https://api.github.com/page/3", hash_including(:headers)).once
      expect(HTTParty).to have_received(:get).with("https://api.github.com/page/2", hash_including(:headers)).once
      expect(HTTParty).to have_received(:get).with("https://api.github.com/page/1", hash_including(:headers)).once
      expect(events.pluck("id")).to eq(%w[3 2 1])
    end

    it "stops paging when old events include a timestamp-less commit event" do
      first_page = instance_double(
        HTTParty::Response,
        success?: true,
        body: [].to_json,
        headers: { "link" => '<https://api.github.com/page/2>; rel="last"' }
      )
      last_page = instance_double(
        HTTParty::Response,
        success?: true,
        body: [
          { "id" => "2", "event" => "committed" },
          { "id" => "1", "created_at" => "2026-10-05T09:00:00Z" }
        ].to_json,
        headers: { "link" => '<https://api.github.com/page/1>; rel="prev"' }
      )
      allow(service).to receive(:activity_since).and_return(Time.zone.parse("2026-10-05T10:00:00Z"))
      allow(HTTParty).to receive(:get).and_return(first_page, last_page)

      events = service.send(:timeline_events, "repository_url" => "https://api.github.com/repos/org/repo", "number" => 5)

      expect(HTTParty).not_to have_received(:get).with("https://api.github.com/page/1", hash_including(:headers))
      expect(events.pluck("id")).to eq(%w[2 1])
    end

    it "continues paging past a page containing only timestamp-less commit events" do
      first_page = instance_double(
        HTTParty::Response,
        success?: true,
        body: [].to_json,
        headers: { "link" => '<https://api.github.com/page/2>; rel="last"' }
      )
      commit_page = instance_double(
        HTTParty::Response,
        success?: true,
        body: [{ "id" => "2", "event" => "committed" }].to_json,
        headers: { "link" => '<https://api.github.com/page/1>; rel="prev"' }
      )
      recent_event_page = instance_double(
        HTTParty::Response,
        success?: true,
        body: [{ "id" => "1", "created_at" => "2026-10-05T11:00:00Z" }].to_json,
        headers: {}
      )
      allow(service).to receive(:activity_since).and_return(Time.zone.parse("2026-10-05T10:00:00Z"))
      allow(HTTParty).to receive(:get).and_return(first_page, commit_page, recent_event_page)

      events = service.send(:timeline_events, "repository_url" => "https://api.github.com/repos/org/repo", "number" => 5)

      expect(HTTParty).to have_received(:get).with("https://api.github.com/page/1", hash_including(:headers)).once
      expect(events.pluck("id")).to eq(%w[2 1])
    end

    it "raises when the first activity request fails so the sync is retried" do
      failed_response = instance_double(HTTParty::Response, success?: false, code: 503)
      allow(HTTParty).to receive(:get).and_return(failed_response)

      expect do
        service.send(:timeline_events, "repository_url" => "https://api.github.com/repos/org/repo", "number" => 5)
      end.to raise_error(
        Github::Service::ActivityFetchError,
        "Error loading Github activity from https://api.github.com/repos/org/repo/issues/5/timeline (response code: 503)"
      )
    end

    it "raises when a paginated activity request fails so the sync is retried" do
      first_page = instance_double(
        HTTParty::Response,
        success?: true,
        body: [].to_json,
        headers: { "link" => '<https://api.github.com/page/2>; rel="last"' }
      )
      failed_response = instance_double(HTTParty::Response, success?: false, code: 429)
      allow(HTTParty).to receive(:get).and_return(first_page, failed_response)

      expect do
        service.send(:timeline_events, "repository_url" => "https://api.github.com/repos/org/repo", "number" => 5)
      end.to raise_error(
        Github::Service::ActivityFetchError,
        "Error loading Github activity from https://api.github.com/page/2 (response code: 429)"
      )
    end

    it "retrieves pull-request reviews but not reviews for issues" do
      issue = instance_double(Github::Issue, persisted?: true, is_pr: false)
      pull_request = instance_double(Github::Issue, persisted?: true, is_pr: true)
      external_issue = { "repository_url" => "https://api.github.com/repos/org/repo", "number" => 5 }
      allow(service).to receive(:timeline_events).and_return([])
      allow(service).to receive(:review_events).and_return([])
      allow(service).to receive(:activity_since).and_return(Time.zone.parse("2026-10-05T10:00:00Z"))
      allow(Github::ActivityEmitter).to receive(:emit_for)

      service.send(:publish_activity_for, issue, external_issue)
      service.send(:publish_activity_for, pull_request, external_issue)

      expect(service).to have_received(:review_events).with(external_issue).once
    end

    it "does not retrieve activity for an item unchanged since the last sync" do
      issue = instance_double(Github::Issue, persisted?: true)
      external_issue = { "updated_at" => "2026-10-05T09:00:00Z" }
      allow(service).to receive(:activity_since).and_return(Time.zone.parse("2026-10-05T10:00:00Z"))
      expect(service).not_to receive(:timeline_events)
      expect(service).not_to receive(:review_events)
      expect(Github::ActivityEmitter).not_to receive(:emit_for)

      service.send(:publish_activity_for, issue, external_issue)
    end

    it "retrieves activity for an item updated at the sync cursor" do
      issue = instance_double(Github::Issue, persisted?: true, is_pr: false)
      external_issue = { "updated_at" => "2026-10-05T10:00:00Z" }
      allow(service).to receive(:activity_since).and_return(Time.zone.parse("2026-10-05T10:00:00Z"))
      allow(service).to receive(:timeline_events).and_return([])
      allow(Github::ActivityEmitter).to receive(:emit_for)

      service.send(:publish_activity_for, issue, external_issue)

      expect(service).to have_received(:timeline_events).with(external_issue)
      expect(Github::ActivityEmitter).to have_received(:emit_for).with(issue, events: [], since: service.send(:activity_since))
    end

    it "publishes an opened activity for a newly opened pull request" do
      external_pr = {
        "id" => 123,
        "number" => 5,
        "title" => "Ship activity feed",
        "state" => "open",
        "body" => "notes",
        "html_url" => "https://github.com/org/repo/pull/5",
        "created_at" => "2026-10-05T11:00:00Z",
        "updated_at" => "2026-10-05T11:00:00Z",
        "user" => { "login" => "octocat" },
        "pull_request" => { "diff_url" => "https://github.com/org/repo/pull/5.diff" },
        "repository_url" => "https://api.github.com/repos/org/repo",
        "labels" => []
      }
      item = Github::Issue.new(
        github_issue: external_pr,
        options: { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] },
        external_id: "123",
        source_service_name: "github"
      ).tap(&:refresh_from_external!)
      allow(service).to receive(:activity_since).and_return(Time.zone.parse("2026-10-05T10:00:00Z"))

      service.send(:publish_activity_for, item, external_pr)

      activity = OutboxEntry.where(record_kind: "observation").where.not(event_type: "snapshot_seen")
                            .sole.payload.fetch("activity")
      expect(activity).to include("type" => "opened", "source_event_id" => "123-opened", "actor" => "octocat")
    end
  end

  describe "#should_sync?" do
    subject { service.should_sync?(task_updated_at) }

    context "when task_updated_at is nil" do
      let(:task_updated_at) { nil }

      context "when last sync was less than min_sync_interval" do
        let(:last_sync) { Time.now - Chronic.parse("29 minutes ago") }

        it { is_expected.to be false }
      end

      context "when last sync was more than min_sync_interval" do
        let(:last_sync) { Time.now - Chronic.parse("61 minutes ago") }

        it { is_expected.to be true }
      end
    end

    context "when task_updated_at is less than min_sync_interval" do
      let(:task_updated_at) { Chronic.parse("29 minutes ago") }

      it { is_expected.to be true }
    end

    context "when task_updated_at is more than min_sync_interval" do
      let(:task_updated_at) { Chronic.parse("61 minutes ago") }

      it { is_expected.to be false }
    end
  end

  describe "#sync_repositories" do
    it "returns an empty array when repositories option is nil" do
      allow(service).to receive(:options).and_return({ repositories: nil })
      expect(service.send(:sync_repositories)).to eq([])
    end
  end
end
