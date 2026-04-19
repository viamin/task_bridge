# frozen_string_literal: true

class AddIndexOnSyncItemsLastModified < ActiveRecord::Migration[7.1]
  def change
    add_index :sync_items, :last_modified
  end
end
