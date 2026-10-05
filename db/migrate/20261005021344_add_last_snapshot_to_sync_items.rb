# frozen_string_literal: true

class AddLastSnapshotToSyncItems < ActiveRecord::Migration[8.1]
  def change
    add_column :sync_items, :last_snapshot, :json
  end
end
