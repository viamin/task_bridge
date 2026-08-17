# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reclaim::Service" do
  let(:service) { Reclaim::Service.new(options: service_options) }
  let(:service_options) do
    { tags: [], personal_tags: [], work_tags: [], primary: "Omnifocus", services: %w[Asana Reminders Github GoogleTasks Reclaim Instapaper] }
  end
  let(:reclaim_task) do
    {
      "id" => "reclaim-123",
      "title" => "Reclaim task"
    }
  end
  let(:task) { instance_double(Reclaim::Task, "reclaim_task=": reclaim_task) }

  before do
    allow(service).to receive(:list_tasks).and_return([reclaim_task])
    allow(Reclaim::Task).to receive(:find_or_initialize_by_source).with(
      service_name: service.service_name,
      external_id: "reclaim-123"
    ).and_return(task)
    allow(task).to receive(:options).and_return({})
    allow(task).to receive(:options=)
    allow(task).to receive(:refresh_from_external!).and_return(task)
  end

  it "hydrates tasks using the caller's requested refresh mode" do
    service.items_to_sync(only_modified_dates: false)

    expect(task).to have_received(:refresh_from_external!).with(only_modified_dates: false)
  end

  it "preserves partial refresh behavior when requested" do
    service.items_to_sync(only_modified_dates: true)

    expect(task).to have_received(:refresh_from_external!).with(only_modified_dates: true)
  end

  describe "#update_item" do
    subject { service.update_item(reclaim_task, external_task) }

    let(:reclaim_task) { Reclaim::Task.new(external_id: "reclaim-123", options: service_options) }
    let(:external_task) { instance_double(Asana::Task) }
    let(:task_data) { { title: "Updated title", notes: "ignored by override" } }
    let(:merged_notes) { "body\nreclaim_id: reclaim-123" }
    let(:httparty_success_mock) do
      instance_double(HTTParty::Response, success?: true, body: "{}")
    end

    before do
      allow(Reclaim::Task).to receive(:from_external).with(external_task).and_return(task_data)
      allow(reclaim_task).to receive(:sync_notes_from).with(external_task).and_return(merged_notes)
      allow(HTTParty).to receive(:patch).and_return(httparty_success_mock)
      allow(service).to receive(:update_sync_data)
    end

    it "merges source content with this task's sync IDs into the PATCH payload" do
      expect(reclaim_task).to receive(:sync_notes_from).with(external_task).and_return(merged_notes)
      expect(HTTParty).to receive(:patch) do |_url, opts|
        payload = JSON.parse(opts[:body])
        expect(payload["notes"]).to eq(merged_notes)
        httparty_success_mock
      end

      service.update_item(reclaim_task, external_task)
    end
  end
end
