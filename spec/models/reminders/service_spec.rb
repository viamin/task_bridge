# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reminders::Service" do
  let(:service) { Reminders::Service.new }
  let(:reminders_mapping) { "" }
  let(:logger) { double(StructuredLogger) }
  let(:last_sync) { Time.now - service.send(:min_sync_interval) }
  let(:options) { { reminders_mapping:, tags: [] } }

  before do
    allow_any_instance_of(StructuredLogger).to receive(:sync_data_for).and_return({})
    allow_any_instance_of(StructuredLogger).to receive(:last_synced).and_return(last_sync)
    allow_any_instance_of(GlobalOptions).to receive(:options).and_return(options)
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
  end

  describe "#add_item" do
  end

  describe "#update_item" do
  end
end
