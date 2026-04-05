# frozen_string_literal: true

require "rails_helper"

RSpec.describe Asana::Service, :full_options do
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}) }
  let(:base_options) do
    full_options.merge(
      logger: logger,
      sync_started_at: "2024-01-01 09:00AM",
      quiet: true,
      debug: false,
      pretend: false
    )
  end
  let(:options) { base_options }

  subject(:service) { described_class.new(options: options) }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(Time.now - 1.hour)
  end

  describe "#add_item" do
    let(:external_task) do
      instance_double(
        "ExternalTask",
        title: "Test Task",
        completed?: false,
        due_date: nil,
        flagged: false,
        project: "Pets:Bucky",
        sync_notes: "notes",
        patch_external_attributes: true
      )
    end
    let(:created_task_data) do
      JSON.parse(File.read(File.expand_path(File.join(__dir__, "..", "..", "fixtures", "asana_task.json"))))
    end
    let(:response) do
      instance_double(HTTParty::Response, success?: true, body: { data: created_task_data }.to_json)
    end

    before do
      allow(HTTParty).to receive(:post).and_return(response)
      allow(service).to receive(:memberships_for_task).with(external_task, for_create: true).and_return({ projects: ["project-gid"] })
      allow(service).to receive(:section_identifier_for).with(external_task).and_return("section-gid")
      allow(service).to receive(:move_task_to_section).and_return(nil)
    end

    it "hydrates the created task before using its sync attributes" do
      expect(service).to receive(:handle_sub_items) do |new_task, task|
        expect(task).to eq(external_task)
        expect(new_task.external_id).to eq(created_task_data["gid"])
        expect(new_task.url).to eq(created_task_data["permalink_url"])
      end
      expect(service).to receive(:update_sync_data).with(
        external_task,
        created_task_data["gid"],
        created_task_data["permalink_url"]
      )

      service.add_item(external_task)
    end

    it "returns the created task on success so the sync collection can be persisted" do
      created_task = service.add_item(external_task)

      expect(created_task).to be_a(Asana::Task)
      expect(created_task.external_id).to eq(created_task_data["gid"])
    end
  end
end
