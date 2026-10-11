# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxSeeder do
  let(:item_classes) do
    {
      omnifocus: stub_item_class("BackfillOmniFocusItem", "Omnifocus"),
      asana: stub_item_class("BackfillAsanaItem", "Asana"),
      github: stub_item_class("BackfillGithubItem", "Github"),
      google_tasks: stub_item_class("BackfillGoogleTasksItem", "GoogleTasks")
    }
  end

  def stub_item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end

  def create_item(type, collection:, external_id:, notes: nil)
    item_classes.fetch(type).create!(
      title: "Release checklist",
      external_id:,
      notes:,
      sync_collection: collection,
      options: {
        service_name: item_classes.fetch(type).name.delete_prefix("Backfill").delete_suffix("Item"),
        services: [],
        primary: "OmniFocus",
        tags: []
      }
    )
  end

  it "seeds idempotent baseline item snapshots and only publishable mappings" do
    confirmed = SyncCollection.create!(title: "Release checklist")
    inferred = SyncCollection.create!(title: "Release checklist")
    withheld = SyncCollection.create!(title: "Needs review")
    omnifocus = create_item(:omnifocus, collection: confirmed, external_id: "of-1", notes: "asana_id: asana-1")
    create_item(:asana, collection: confirmed, external_id: "asana-1", notes: "omnifocus_id: of-1")
    create_item(:github, collection: inferred, external_id: "gh-1")
    create_item(:google_tasks, collection: inferred, external_id: "gt-1")
    create_item(:github, collection: withheld, external_id: "gh-review")

    first_summary = described_class.run!

    expect(first_summary).to include(
      items: include("omnifocus" => 1, "asana" => 1, "github" => 2, "google_tasks" => 1),
      mappings: include("high" => 2, "medium" => 2),
      skipped: include(mapping_low: 1)
    )
    expect(OutboxEntry.where(record_kind: "item").count).to eq(5)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly("of-1", "asana-1", "gh-1", "gt-1")

    omnifocus_row = OutboxEntry.find_by!(record_kind: "item", external_id: "of-1")
    expect(omnifocus_row.service_instance).to eq("omnifocus:default")
    expect(omnifocus_row.payload).to include(
      "observed_at" => omnifocus.last_observed_at.utc.iso8601(6),
      "provenance" => include("detected_by" => "backfill", "backfilled_at" => be_present)
    )
    expect(omnifocus.reload.last_snapshot).to be_present
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:payload)).to include(
      include("mapping_confidence" => "confirmed"),
      include("mapping_confidence" => "inferred")
    )

    expect { described_class.run! }.not_to change(OutboxEntry, :count)
  end

  it "reports prospective rows without changing local provenance, snapshots, or the outbox" do
    collection = SyncCollection.create!(title: "Needs review")
    item = create_item(:omnifocus, collection:, external_id: "of-1")
    item.update_columns(source_service_name: nil, source_service_instance: nil, source_service_type: nil,
                        source_external_id: nil, first_observed_at: nil, last_observed_at: nil)

    summary = described_class.run!(dry_run: true)

    expect(summary).to include(items: include("omnifocus" => 1), skipped: include(mapping_low: 1))
    expect(item.reload).to have_attributes(source_service_name: nil, last_snapshot: nil)
    expect(OutboxEntry.count).to eq(0)
  end
end
