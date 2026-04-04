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
    end

    it "loads external_id from the shared external attribute map" do
      expect(subject.map(&:external_id)).to eq([external_issue["id"].to_s])
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
end
