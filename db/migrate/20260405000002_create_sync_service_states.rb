# frozen_string_literal: true

class CreateSyncServiceStates < ActiveRecord::Migration[7.1]
  def change
    create_table :sync_service_states do |t|
      t.string :service_name, null: false
      t.string :status
      t.integer :items_synced, null: false, default: 0
      t.text :detail
      t.datetime :last_attempted_at
      t.datetime :last_successful_at
      t.datetime :last_failed_at

      t.timestamps
    end

    add_index :sync_service_states, :service_name, unique: true
    add_index :sync_service_states, :last_successful_at
  end
end
