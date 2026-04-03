# frozen_string_literal: true

class AddUniqueIndexOnSyncItemsTypeAndExternalId < ActiveRecord::Migration[7.2]
  def change
    add_index :sync_items, %i[type external_id], unique: true
  end
end
