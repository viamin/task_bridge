# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Reminders::Service", :full_options do
  let(:service) { Reminders::Service.new(options:) }
  let(:options) { full_options.merge({ reminders_mapping: }) }
  let(:reminders_mapping) { "" }
  let(:last_sync) { Time.now - service.send(:min_sync_interval) }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(last_sync)
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
        expect(subject.first.title).to eq("Test Reminder with all the fixings")
      end
    end
  end

  describe "#add_item" do
  end

  describe "#update_item" do
  end
end
