# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Reminders::Reminder" do
  let(:service) { Reminders::Service.new }
  let(:reminder) { Reminders::Reminder.new(reminder: properties, options:) }
  let(:options) { { tags: [] } }
  let(:id) { "x-apple-reminder://#{SecureRandom.uuid.upcase}" }
  let(:name) { Faker::Lorem.sentence }
  let(:completed) { [true, false].sample }
  let(:containing_list) { SecureRandom.uuid.upcase }
  let(:body) { "notes" }
  let(:properties) do
    OpenStruct.new({
      id:,
      name:,
      completed:,
      containing_list:,
      body:
    }.compact)
  end

  describe "new" do
    it "parses out the sync_id from notes" do
      expect(reminder.sync_id).to eq("jU466dYHf2o")
    end
  end

  describe "#sync_notes" do
    let(:body) { "notes\n\nsync_id: jU466dYHf2o\n" }

    it "adds a sync_id to the notes" do
      expect(reminder.notes).to eq("notes")
      expect(reminder.sync_id).to eq("jU466dYHf2o")
      expect(reminder.sync_notes).to eq("notes\n\nsync_id: jU466dYHf2o\n")
    end
  end
end
