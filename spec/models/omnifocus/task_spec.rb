# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Omnifocus::Task" do
  let(:service) { Omnifocus::Service.new }
  let(:task) { Omnifocus::Task.new(omnifocus_task: properties) }
  let(:id) { SecureRandom.alphanumeric(11) }
  let(:name) { Faker::Lorem.sentence }
  let(:notes) { "notes" }
  let(:completed) { [true, false].sample }
  let(:containing_project) { "Folder:Project" }
  let(:tasks) { [] }
  let(:tags) { [] }
  let(:properties) do
    OpenStruct.new({
      id_: id,
      name:,
      completed:,
      note: notes,
      containing_project:,
      tags: tags.map { |tag| OpenStruct.new({name: tag}) },
      tasks:
    }.compact)
  end

  it_behaves_like "sync_item" do
    let(:item) { task }
  end

  context "with time-related tags" do
    context "with a relative date tag" do
      let(:tags) { ["This Week"] }

      it "sets a due date to this week" do
        expect(task.due_date).to eq(Chronic.parse("the end of this week"))
      end
    end

    context "with a month tag" do
      let(:tags) { ["12 - December"] }

      it "sets a due date in December" do
        # This spec will fail during December
        expect(task.due_date).to eq(Chronic.parse("12 - December"))
      end

      context "when the date is in the past" do
        let(:tags) { ["01 - January"] }

        it "sets a due date in the future" do
          expect(task.due_date).to be > Time.now
        end
      end
    end

    context "with a weekday tag" do
      let(:tags) { ["Tuesday"] }

      it "sets a due date of next Tuesday" do
        expect(task.due_date).to eq(Chronic.parse("Next Tuesday"))
      end
    end
  end
end
