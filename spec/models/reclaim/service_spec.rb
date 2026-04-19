# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reclaim::Service" do
  let(:service) { Reclaim::Service.new(options: { tags: [], personal_tags: [], work_tags: [] }) }
  let(:reclaim_task) do
    {
      "id" => "reclaim-123",
      "title" => "Reclaim task"
    }
  end
  let(:task) { instance_double(Reclaim::Task, "reclaim_task=": reclaim_task) }

  before do
    allow(service).to receive(:list_tasks).and_return([reclaim_task])
    allow(Reclaim::Task).to receive(:find_or_initialize_by).with(external_id: "reclaim-123").and_return(task)
    allow(task).to receive(:refresh_from_external!).and_return(task)
  end

  it "hydrates tasks using the caller's requested refresh mode" do
    service.items_to_sync(only_modified_dates: false)

    expect(task).to have_received(:refresh_from_external!).with(only_modified_dates: false)
  end

  it "preserves partial refresh behavior when requested" do
    service.items_to_sync(only_modified_dates: true)

    expect(task).to have_received(:refresh_from_external!).with(only_modified_dates: true)
  end
end
