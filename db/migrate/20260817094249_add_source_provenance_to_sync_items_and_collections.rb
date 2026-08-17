# frozen_string_literal: true

class AddSourceProvenanceToSyncItemsAndCollections < ActiveRecord::Migration[8.1]
  def change
    change_table :sync_items, bulk: true do |t|
      t.string :source_service_name
      t.string :source_service_instance
      t.string :source_service_type
      t.string :source_external_id
      t.string :source_url
      t.datetime :source_created_at
      t.datetime :source_updated_at
      t.datetime :first_observed_at
      t.datetime :last_observed_at
      t.text :source_metadata
    end

    change_table :sync_collections, bulk: true do |t|
      t.string :mapping_method
      t.string :mapping_confidence
      t.text :mapping_metadata
      t.datetime :mapping_established_at
      t.datetime :mapping_last_observed_at
    end

    remove_index :sync_items, name: "index_sync_items_on_type_and_external_id"
    add_index :sync_items, %i[type source_service_name external_id],
              unique: true,
              name: "index_sync_items_on_type_service_name_and_external_id"

    remove_index :sync_items, name: "index_sync_items_on_sync_collection_id_and_type"
    add_index :sync_items, %i[sync_collection_id source_service_name],
              unique: true,
              where: "sync_collection_id IS NOT NULL AND source_service_name IS NOT NULL",
              name: "index_sync_items_on_collection_id_and_source_service_name"
  end
end
