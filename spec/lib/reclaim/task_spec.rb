# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Reclaim::Task", :full_options do
  let(:service) { Reclaim::Service.new }
  let(:task) { Reclaim::Task.new(reclaim_task: properties, options:) }
  let(:id) { Faker::Number.number(digits: 7) }
  let(:title) { Faker::Lorem.sentence }
  let(:notes) { "notes" }
  let(:start_date) { "Today" }
  let(:due_date) { "Tomorrow" }
  let(:event_category) { %w[WORK PERSONAL].sample }
  let(:properties) do
    {
      "id" => id,
      "title" => title,
      "due" => due_date,
      "snoozeUntil" => start_date,
      "notes" => notes,
      "eventCategory" => event_category
    }.compact
  end

  it_behaves_like "sync_item" do
    let(:item) { task }
  end

  it "parses the due_date" do
    expect(task.due_date).to be_instance_of(Time)
  end

  it "parses the start_date" do
    expect(task.start_date).to be_instance_of(Time)
  end

  context "when eventCatgory is personal" do
    let(:event_category) { Reclaim::Task::PERSONAL }

    it "is personal" do
      expect(task).to be_personal
    end
  end
end
