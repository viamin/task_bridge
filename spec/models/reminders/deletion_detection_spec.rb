# frozen_string_literal: true

require "rails_helper"

# Reminders side of deletion detection (#220): the mapped lists are a
# complete enumeration, so absence is a real disappearance — but a missing
# (renamed/deleted) Reminders list must never look like mass deletion.
RSpec.describe "Reminders deletion detection" do
  let(:options) do
    {
      logger: double(StructuredLogger, sync_data_for: {}, last_synced: Time.current - 5.minutes),
      quiet: true,
      debug: false,
      pretend: false,
      service_name: "Reminders",
      reminders_mapping: "TaskBridge~TaskBridge:Test",
      tags: [],
      services: [],
      primary: "Omnifocus"
    }
  end
  let(:service) { Reminders::Service.new(options:) }
  let(:reminders_app) { double("RemindersApp") }
  let(:taskbridge_list) { double("TaskBridgeList", name: double(get: "TaskBridge")) }

  def persisted_reminder(external_id)
    Reminders::Reminder.create!(external_id:, title: "Reminder #{external_id}", source_service_name: service.service_name)
  end

  def stub_lists(*lists)
    allow(reminders_app).to receive(:lists).and_return(double(get: lists))
  end

  before do
    allow(Appscript).to receive(:app).and_return(double(by_name: reminders_app))
  end

  it "enqueues a no_longer_visible tombstone for a vanished reminder" do
    stub_lists(taskbridge_list)
    existing = double("ExistingReminder", id_: double(get: "reminder-1"))
    allow(taskbridge_list).to receive(:reminders).and_return(double(get: [existing]))
    persisted_reminder("reminder-2")

    service.items_to_sync

    entries = OutboxEntry.where(record_kind: "observation", event_type: "deleted")
    expect(entries.count).to eq(1)
    payload = entries.first.payload
    expect(payload["disappearance_state"]).to eq("no_longer_visible")
    expect(payload["is_deleted"]).to be(false)
    expect(payload["provenance"]).to match(hash_including("confidence" => "medium"))
    expect(entries.first.external_id).to eq("reminder-2")
  end

  it "emits nothing when a mapped list is missing" do
    other_list = double("OtherList", name: double(get: "Other List"))
    stub_lists(other_list)
    allow(other_list).to receive(:reminders).and_return(double(get: []))
    persisted_reminder("reminder-1")

    service.items_to_sync

    expect(OutboxEntry.count).to eq(0)
  end

  it "emits nothing in pretend mode" do
    stub_lists(taskbridge_list)
    allow(taskbridge_list).to receive(:reminders).and_return(double(get: []))
    persisted_reminder("reminder-1")
    pretend_service = Reminders::Service.new(options: options.merge(pretend: true))

    allow(reminders_app).to receive(:lists).and_return(double(get: [taskbridge_list]))
    pretend_service.items_to_sync

    expect(OutboxEntry.count).to eq(0)
  end
end
