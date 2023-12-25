# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reminders::Reminder", :full_options do
  let(:service) { Reminders::Service.new }
  let(:reminder) { Reminders::Reminder.new(reminder: properties, options:) }
  let(:id) { "x-apple-reminder://#{SecureRandom.uuid.upcase}" }
  let(:name) { Faker::Lorem.sentence }
  let(:completed) { [true, false].sample }
  let(:containing_list) { SecureRandom.uuid.upcase }
  let(:body) { "notes\n\nomnifocus_id: jU466dYHf2o" }
  let(:properties) do
    OpenStruct.new({
      id:,
      name:,
      completed:,
      containing_list:,
      body:
    }.compact)
  end

  it_behaves_like "sync_item" do
    let(:item) { reminder }
  end

  describe "new" do
    it "parses out the omnifocus_id from notes" do
      expect(reminder.omnifocus_id).to eq("jU466dYHf2o")
    end
  end
end
