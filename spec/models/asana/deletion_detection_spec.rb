# frozen_string_literal: true

require "rails_helper"

# Incremental/filtered source coverage for deletion detection (#220): Asana's
# project task list query is filtered, so absence alone proves nothing. Each
# candidate is verified by direct task lookup, and inconclusive lookups
# (outage, auth, expected completion aging) must not create tombstones.
RSpec.describe "Asana deletion detection" do
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}, last_synced: Time.current - 1.hour) }
  let(:options) do
    {
      logger:,
      quiet: true,
      debug: false,
      pretend: false,
      service_name: "Asana",
      primary: "Omnifocus",
      services: [],
      tags: ["TaskBridge"]
    }
  end
  subject(:service) { Asana::Service.new(options:) }

  let(:task_data) do
    JSON.parse(File.read(File.expand_path("../../fixtures/asana_task.json", __dir__))).merge(
      "gid" => "asana-present",
      "name" => "Present task",
      "num_subtasks" => 0
    )
  end

  def persisted_asana_task(external_id, attributes = {})
    Asana::Task.create!({ external_id:, title: "Task #{external_id}", source_service_name: service.service_name }.merge(attributes))
  end

  def lookup_response(code:, body: {})
    double("response", code:, success?: code.between?(200, 299), body: body.to_json)
  end

  def stub_task_lookup(external_id, response)
    allow(HTTParty).to receive(:get)
      .with("https://app.asana.com/api/1.0/tasks/#{external_id}", kind_of(Hash))
      .and_return(response)
  end

  def tombstones
    OutboxEntry.where(record_kind: "observation", event_type: "deleted")
  end

  before do
    allow(service).to receive(:list_projects).and_return([{ "gid" => "project-gid" }])
    allow(service).to receive(:list_project_tasks).with("project-gid", only_modified_dates: false).and_return([task_data])
    allow(service).to receive(:list_task_sub_items)
  end

  it "verifies missing tasks and emits per-outcome tombstones" do
    persisted_asana_task("asana-present")
    persisted_asana_task("asana-deleted")
    persisted_asana_task("asana-archived")
    persisted_asana_task("asana-moved")
    stub_task_lookup("asana-deleted", lookup_response(code: 404, body: { "errors" => [{ "message" => "Not Found" }] }))
    stub_task_lookup("asana-archived", lookup_response(code: 200, body: { "data" => { "archived" => true } }))
    stub_task_lookup("asana-moved", lookup_response(code: 200, body: { "data" => { "archived" => false, "completed" => false } }))

    service.items_to_sync

    states = tombstones.index_by(&:external_id).transform_values { |entry| entry.payload["disappearance_state"] }
    expect(states).to eq(
      "asana-deleted" => "source_deleted",
      "asana-archived" => "source_archived",
      "asana-moved" => "no_longer_visible"
    )
    deleted_payload = tombstones.find { |entry| entry.external_id == "asana-deleted" }.payload
    expect(deleted_payload["is_deleted"]).to be(true)
    archived_payload = tombstones.find { |entry| entry.external_id == "asana-archived" }.payload
    expect(archived_payload["is_deleted"]).to be(false)
    expect(archived_payload["provenance"]).to include("confidence" => "high")
    moved_payload = tombstones.find { |entry| entry.external_id == "asana-moved" }.payload
    expect(moved_payload["provenance"]).to include("confidence" => "medium")
  end

  it "emits nothing for a task that exists but completed (expected absence)" do
    persisted_asana_task("asana-completed-source")
    stub_task_lookup("asana-completed-source", lookup_response(code: 200, body: { "data" => { "completed" => true } }))

    service.items_to_sync

    expect(tombstones.count).to eq(0)
  end

  it "emits nothing when verification is inconclusive (outage/auth)" do
    persisted_asana_task("asana-outage")
    stub_task_lookup("asana-outage", lookup_response(code: 503, body: { "errors" => [] }))

    service.items_to_sync

    expect(tombstones.count).to eq(0)
  end

  it "does not verify or emit for locally completed tasks (completion window aging)" do
    persisted_asana_task("asana-old-complete", completed_at: Time.current - 2.weeks)

    expect(HTTParty).not_to receive(:get)
    service.items_to_sync

    expect(tombstones.count).to eq(0)
  end

  it "emits nothing during a partial (only_modified_dates) fetch" do
    allow(service).to receive(:list_project_tasks).with("project-gid", only_modified_dates: true).and_return([task_data])
    persisted_asana_task("asana-deleted")

    expect(HTTParty).not_to receive(:get)
    service.items_to_sync(only_modified_dates: true)

    expect(tombstones.count).to eq(0)
  end

  it "does not tombstone observed subtasks" do
    parent_data = task_data.merge("gid" => "asana-parent", "num_subtasks" => 1)
    subtask_data = task_data.merge("gid" => "asana-subtask", "num_subtasks" => 0)
    allow(service).to receive(:list_project_tasks).with("project-gid", only_modified_dates: false).and_return([parent_data])
    allow(service).to receive(:list_task_sub_items).with("asana-parent", only_modified_dates: false).and_return([subtask_data])
    persisted_asana_task("asana-subtask")

    service.items_to_sync

    expect(tombstones.count).to eq(0)
  end
end
