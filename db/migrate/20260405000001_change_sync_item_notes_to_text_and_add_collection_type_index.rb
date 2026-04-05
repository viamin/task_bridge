# frozen_string_literal: true

class ChangeSyncItemNotesToTextAndAddCollectionTypeIndex < ActiveRecord::Migration[7.2]
  def change
    change_column :sync_items, :notes, :text
    add_index :sync_items, %i[sync_collection_id type],
              unique: true,
              where: "sync_collection_id IS NOT NULL"
  end
end
