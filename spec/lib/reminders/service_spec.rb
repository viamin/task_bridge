# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Reminders::Service", :full_options do
  let(:logger) { instance_double(StructuredLogger) }
  let(:options) { full_options.merge({ reminders_mapping:, logger: }) }
  let(:service) { Reminders::Service.new(options:) }
  let(:reminders_mapping) { "" }
  let(:last_sync) { Time.now - (5 * 60) }
  let(:reminders_app) { instance_double("RemindersApp") }
  let(:reminder_lists) { {} }

  def build_reminder_double(data)
    double(
      "RemindersReminder",
      id: data.fetch(:id),
      title: data.fetch(:title),
      list: data.fetch(:list, "Default")
    )
  end

  before do
    allow(Appscript).to receive_message_chain(:app, :by_name).and_return(reminders_app)
    allow(logger).to receive(:sync_data_for).with("Reminders").and_return({})
    allow(logger).to receive(:last_synced).and_return(last_sync)
    allow(service).to receive(:reminders_in_list) { |list_name| reminder_lists.fetch(list_name, []) }
    allow(Reminders::Reminder).to receive(:new) do |reminder:, options:|
      build_reminder_double(reminder)
    end
  end

  describe "#items_to_sync" do
    subject { service.items_to_sync }

    it "returns an empty array", :no_ci do
      expect(subject).to eq([])
    end

    context "with a mapping" do
      let(:reminders_mapping) { "TaskBridge~TaskBridge:Test" }
      let(:reminder_lists) do
        {
          "TaskBridge" => [
            { id: "reminder-1", title: "Test Reminder with all the fixings", list: "TaskBridge" }
          ]
        }
      end

      it "returns tasks in a list", :no_ci do
        expect(subject.count).to eq(1)
        expect(subject.first.title).to eq("Test Reminder with all the fixings")
      end

      it "fetches reminders from the mapped lists", :no_ci do
        subject
        expect(service).to have_received(:reminders_in_list).with("TaskBridge")
      end
    end
  end
end
