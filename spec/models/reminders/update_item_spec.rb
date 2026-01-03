# frozen_string_literal: true

require "spec_helper"

RSpec.describe Reminders::Service do
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}) }
  let(:reminders_app) { instance_double("RemindersApp") }
  let(:base_options) do
    {
      logger: logger,
      services: [],
      sync_started_at: "2024-01-01 09:00AM",
      quiet: true,
      debug: false,
      reminders_mapping: ""
    }
  end
  let(:options) { base_options }

  subject(:service) { described_class.new(options:) }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(Appscript).to receive_message_chain(:app, :by_name).and_return(reminders_app)
  end

  describe "#update_item" do
    let(:reminder) do
      instance_double(
        "ReminderItem",
        incomplete?: true,
        title: "Test Reminder"
      )
    end
    let(:external_task) do
      instance_double(
        "ExternalTask",
        completed?: task_completed,
        updated_at: Time.now,
        title: "Test Reminder",
        sync_notes: "notes"
      )
    end
    let(:reminder_id_accessor) { instance_double("ReminderIdAccessor", get: "abc123") }
    let(:task_completed) { true }

    before do
      allow(reminder).to receive(:id_).and_return(reminder_id_accessor)
      allow(external_task).to receive(:update_attributes)
    end

    context "when running in pretend mode" do
      let(:options) { base_options.merge(pretend: true) }

      it "returns a message and does not mark the reminder complete" do
        expect(reminder).not_to receive(:mark_complete)

        result = service.update_item(reminder, external_task)

        expect(result).to eq("Would have marked Test Reminder complete in Reminders")
      end
    end

    context "when completing the reminder" do
      let(:options) { base_options.merge(update_ids_for_existing: true) }

      it "marks the reminder complete and updates sync data" do
        expect(reminder).to receive(:mark_complete)
        expect(service).to receive(:update_sync_data).with(external_task, "abc123")

        result = service.update_item(reminder, external_task)

        expect(result).to eq(external_task)
      end
    end

    context "when the item was matched by title (external task has no sync ID)" do
      let(:options) { base_options.merge(update_ids_for_existing: false) }

      before do
        # Simulate a title match - external_task has no reminders_id
        allow(external_task).to receive(:try).with(:reminders_id).and_return(nil)
        allow(reminder).to receive(:mark_complete)
      end

      it "adds sync ID even when update_ids_for_existing is false" do
        expect(service).to receive(:update_sync_data).with(external_task, "abc123")

        service.update_item(reminder, external_task)
      end
    end

    context "when the item was matched by ID (has sync ID)" do
      let(:options) { base_options.merge(update_ids_for_existing: false) }

      before do
        # Simulate an ID match - external_task already has reminders_id
        allow(external_task).to receive(:try).with(:reminders_id).and_return("abc123")
        allow(reminder).to receive(:mark_complete)
      end

      it "does not update sync data when update_ids_for_existing is false" do
        expect(service).not_to receive(:update_sync_data)

        service.update_item(reminder, external_task)
      end
    end

    context "when the external task is already completed" do
      let(:task_completed) { false }

      it "returns nil" do
        expect(service.update_item(reminder, external_task)).to be_nil
      end
    end
  end
end
