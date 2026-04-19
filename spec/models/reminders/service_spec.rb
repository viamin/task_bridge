# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reminders::Service" do
  let(:service) { Reminders::Service.new(options:) }
  let(:reminders_mapping) { "" }
  let(:logger) { double(StructuredLogger) }
  let(:last_sync) { Time.now - 5.minutes }
  let(:options) do
    {
      logger:,
      quiet: true,
      debug: false,
      pretend: false,
      reminders_mapping:,
      tags: [],
      services: [],
      primary: "Omnifocus"
    }
  end

  before do |example|
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(last_sync)
    skip "Reminders is not available to AppleScript" if example.metadata[:no_ci] && !service.authorized
  end

  describe "#items_to_sync" do
    subject { service.items_to_sync }

    it "returns an empty array", :no_ci do
      expect(subject).to eq([])
    end

    context "with a mapping" do
      let(:reminders_mapping) { "TaskBridge~TaskBridge:Test" }

      it "returns tasks in a list", :no_ci do
        expect(subject.count).to eq(1)
        subject.first.read_original
        expect(subject.first.title).to eq("Test Reminder with all the fixings")
      end
    end

    context "when reminders_mapping is nil" do
      let(:reminders_mapping) { nil }

      it "returns an empty array without crashing" do
        expect(subject).to eq([])
      end
    end

    context "when a reminder reference goes stale while reading the id" do
      let(:reminders_mapping) { "TaskBridge~TaskBridge:Test" }
      let(:stale_id) { double("StaleReminderId") }
      let(:stale_reminder) { double("StaleReminder", id_: stale_id) }
      let(:valid_reminder) { double("ValidReminder", id_: double(get: "reminder-ok")) }
      let(:wrapped_reminder) { instance_double(Reminders::Reminder, "reminder=": nil) }

      before do
        allow(service).to receive(:authorized).and_return(true)
        allow(stale_id).to receive(:get).and_raise(make_stale_reference_error(command: "id_.get"))
        allow(service).to receive(:reminders_in_list).with("TaskBridge").and_return([stale_reminder, valid_reminder])
        allow(Reminders::Reminder).to receive(:find_or_initialize_by).with(external_id: "reminder-ok").and_return(wrapped_reminder)
        allow(wrapped_reminder).to receive(:refresh_from_external!).with(only_modified_dates: true).and_return(wrapped_reminder)
      end

      it "skips the stale reminder and keeps syncing remaining reminders" do
        expect(subject).to eq([wrapped_reminder])
      end
    end
  end
end
