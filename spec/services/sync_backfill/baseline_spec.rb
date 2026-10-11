# frozen_string_literal: true

require "rails_helper"
require "stringio"

RSpec.describe SyncBackfill::Baseline do
  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:providers) do
    {
      "Omnifocus" => "omnifocus-1",
      "Asana" => "asana-1",
      "Github" => "github-1",
      "GoogleTasks" => "google-tasks-1"
    }
  end

  before do
    providers.each_key do |provider|
      stub_const("Baseline#{provider}Item", Class.new(Base::SyncItem) do
        define_method(:provider) { provider }

        define_singleton_method(:attribute_map) { {} }

        define_method(:external_data) { {} }
      end)
    end
  end

  it "backfills idempotent item baselines for representative services" do
    providers.each do |provider, external_id|
      "Baseline#{provider}Item".constantize.create!(
        title: "#{provider} task", external_id:, last_modified: observed_at,
        options: { service_name: provider, services: [], primary: "Asana", tags: [] }
      )
    end

    described_class.run!(output: StringIO.new)
    described_class.run!(output: StringIO.new)

    rows = OutboxEntry.where(record_kind: "item")
    expect(rows.count).to eq(4)
    expect(rows.map(&:service_type)).to contain_exactly("omnifocus", "asana", "github", "google_tasks")
    expect(rows.map(&:service_instance)).to all(end_with(":default"))
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(Base::SyncItem.where.not(last_snapshot: nil).count).to eq(4)
  end

  it "withholds low-confidence mappings and reports them in a non-mutating dry run" do
    collection = SyncCollection.create!(title: "Weak match", mapping_method: "manual_backfill", mapping_confidence: "low")
    item = BaselineAsanaItem.create!(title: "Weak match", external_id: "asana-low", sync_collection: collection,
                                     options: { service_name: "Asana", services: [], primary: "Omnifocus", tags: [] })
    output = StringIO.new

    described_class.run!(dry_run: true, output:)

    expect(output.string).to include("mappings_withheld_low_confidence: 1 (service=asana, confidence=low)")
    expect(OutboxEntry).not_to exist
    expect(item.reload.first_observed_at).to be_present
    expect(item.reload.last_snapshot).to be_nil
  end

  it "publishes inferred mappings for title-derived memberships" do
    collection = SyncCollection.create!(title: "Title match", mapping_method: "title_fallback", mapping_confidence: "medium")
    BaselineGoogleTasksItem.create!(title: "Title match", external_id: "gt-1", sync_collection: collection,
                                    options: { service_name: "GoogleTasks", services: [], primary: "Asana", tags: [] })

    described_class.run!(output: StringIO.new)

    expect(OutboxEntry.find_by(record_kind: "mapping").payload["mapping_confidence"]).to eq("inferred")
  end
end
