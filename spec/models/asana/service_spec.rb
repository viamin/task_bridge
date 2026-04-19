# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Asana::Service" do
  let(:service) { Asana::Service.new }
  let(:min_sync_interval) { service.send(:min_sync_interval) }
  let(:last_sync_time) { Time.now - min_sync_interval }
  let(:interval_since_last_sync) { Time.now - last_sync_time }
  let(:httparty_success_mock) { OpenStruct.new(success?: true, body: { data: { task: external_task.to_json } }.to_json) }

  before do
    allow_any_instance_of(StructuredLogger).to receive(:sync_data_for).and_return({})
    allow_any_instance_of(StructuredLogger).to receive(:last_synced) do |_instance, _service_name, interval: false|
      if interval
        Time.now - last_sync_time
      else
        last_sync_time
      end
    end
  end

  describe "#sync_with_primary" do
    context "with omnifocus" do
      let(:primary_service) { Omnifocus::Service.new }

      it "responds to #sync_with_primary" do
        expect(service).to be_respond_to(:sync_with_primary)
      end
    end
  end

  describe "#items_to_sync" do
    subject { service.items_to_sync }
  end

  describe "incremental fetch cursors" do
    let(:response) { instance_double(HTTParty::Response, success?: true, body: { data: [] }.to_json) }

    before do
      allow(HTTParty).to receive(:get).and_return(response)
    end

    it "does not apply modified_since to full project reads" do
      service.send(:list_project_tasks, "project-gid", only_modified_dates: false)

      expect(HTTParty).to have_received(:get).with(
        "https://app.asana.com/api/1.0/projects/project-gid/tasks",
        hash_including(query: hash_excluding(:modified_since))
      )
    end

    it "applies modified_since to incremental project reads" do
      service.send(:list_project_tasks, "project-gid", only_modified_dates: true)

      expect(HTTParty).to have_received(:get).with(
        "https://app.asana.com/api/1.0/projects/project-gid/tasks",
        hash_including(query: hash_including(:modified_since))
      )
    end

    it "does not apply modified_since to full subtask reads" do
      service.send(:list_task_sub_items, "task-gid", only_modified_dates: false)

      expect(HTTParty).to have_received(:get).with(
        "https://app.asana.com/api/1.0/tasks/task-gid/subtasks",
        hash_including(query: hash_excluding(:modified_since))
      )
    end

    it "applies modified_since to incremental subtask reads" do
      service.send(:list_task_sub_items, "task-gid", only_modified_dates: true)

      expect(HTTParty).to have_received(:get).with(
        "https://app.asana.com/api/1.0/tasks/task-gid/subtasks",
        hash_including(query: hash_including(:modified_since))
      )
    end
  end

  describe "#should_sync?" do
    subject { service.should_sync?(task_updated_at) }

    context "when task_updated_at is nil" do
      let(:task_updated_at) { nil }

      context "when not enough time has passed since last sync" do
        let(:last_sync_time) { (Time.now - min_sync_interval) + 60.seconds }
        let(:interval_since_last_sync) { Time.now - last_sync_time }

        it { is_expected.to be false }
      end

      context "when enough time has passed since last sync" do
        let(:last_sync_time) { (Time.now - min_sync_interval) - 60.seconds }
        let(:interval_since_last_sync) { Time.now - last_sync_time }

        it { is_expected.to be true }
      end
    end

    context "when task_updated_at is less than min_sync_interval" do
      let(:task_updated_at) { Chronic.parse("#{min_sync_interval - 1.second} seconds ago") }

      it { is_expected.to be true }
    end

    context "when task_updated_at is more than min_sync_interval" do
      let(:task_updated_at) { Time.now - (min_sync_interval + 1.minute) }

      it { is_expected.to be false }
    end
  end

  describe "#add_item" do
    subject { service.add_item(external_task, parent_task_gid) }

    let(:external_task) { nil }
    let(:parent_task_gid) { nil }
    let(:title) { "Test" }

    before do
      allow(HTTParty).to receive(:post).and_return(httparty_success_mock)
    end

    it "raises an error" do
      expect { subject }.to raise_error NoMethodError
    end
  end

  describe "#update_item" do
    subject { service.update_item(asana_task, external_task) }

    let(:asana_task) { nil }
    let(:external_task) { nil }

    it "raises an error" do
      expect { subject }.to raise_error NoMethodError
    end
  end

  describe "#skip_create?" do
    subject { service.skip_create?(asana_task) }

    let(:asana_task_json) { JSON.parse(File.read(File.expand_path(Rails.root.join("spec", "fixtures", "asana_task.json")))) }
    let(:asana_task) { Asana::Task.new(asana_task: asana_task_json) }

    context "with a completed task" do
      before { allow(asana_task).to receive(:completed?).and_return(true) }

      it { is_expected.to be true }
    end

    context "with a incomplete task" do
      before { allow(asana_task).to receive(:completed?).and_return(false) }

      context "with a nil assignee" do
        before { allow(asana_task).to receive(:assignee).and_return(nil) }

        it { is_expected.to be false }
      end

      context "with an assignee that matches asana_user" do
        before do
          allow(asana_task).to receive(:assignee).and_return("123")
          allow(service).to receive(:asana_user).and_return({ gid: "123" }.stringify_keys)
        end

        it { is_expected.to be false }
      end

      context "with an assignee that does not match asana_user" do
        before do
          allow(asana_task).to receive(:assignee).and_return("123")
          allow(service).to receive(:asana_user).and_return({ gid: "456" }.stringify_keys)
        end

        it { is_expected.to be true }
      end
    end
  end
end
