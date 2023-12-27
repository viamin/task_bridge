# frozen_string_literal: true

class CreateSyncCollections < ActiveRecord::Migration[7.1]
  def change
    create_table :sync_collections do |t|
      t.string :title
      t.datetime :last_synced

      t.timestamps
    end
  end
end
