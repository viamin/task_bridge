# frozen_string_literal: true

class AddLastSuccessfulActivitySyncAtToSyncServiceStates < ActiveRecord::Migration[8.1]
  def change
    add_column :sync_service_states, :last_successful_activity_sync_at, :datetime
    add_index :sync_service_states, :last_successful_activity_sync_at
  end
end
