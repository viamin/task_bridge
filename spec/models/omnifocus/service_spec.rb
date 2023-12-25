# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Omnifocus::Service", :full_options do
  let(:service) { Omnifocus::Service.new(options:) }
  let(:last_sync) { Time.now - service.send(:min_sync_interval) }

  before do
    allow(logger).to receive(:sync_data_for).and_return({})
    allow(logger).to receive(:last_synced).and_return(last_sync)
  end

  describe "#items_to_sync" do
    subject { service.items_to_sync(tags: sync_tags, inbox:) }

    let(:sync_tags) { nil }
    let(:inbox) { false }

    it "returns an empty array", :no_ci do
      expect(subject).to eq([])
    end

    context "with tags" do
      let(:sync_tags) { ["TaskBridge"] }

      it "returns tasks with a matching tag", :no_ci do
        expect(subject).not_to be_empty
      end
    end

    context "with inbox: true" do
      let(:inbox) { true }

      it "returns inbox tasks", :no_ci do
        expect(subject.length).to eq(service.send(:inbox_tasks).length)
      end
    end
  end

  describe "#add_item" do
  end

  describe "#update_item" do
  end
end
