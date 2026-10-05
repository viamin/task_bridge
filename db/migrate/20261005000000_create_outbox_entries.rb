# frozen_string_literal: true

class CreateOutboxEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :outbox_entries do |t|
      t.string :idempotency_key, null: false
      t.string :record_kind, null: false
      t.integer :payload_version, null: false, default: 1
      t.string :event_type
      t.string :service_type, null: false
      t.string :service_instance
      t.string :external_id
      t.references :sync_collection, foreign_key: true
      t.datetime :observed_at, null: false
      t.datetime :source_updated_at
      t.json :payload, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :published_at
      t.datetime :next_retry_at
      t.string :error_class
      t.text :error_message
      t.timestamps
    end

    add_index :outbox_entries, :idempotency_key, unique: true
    add_index :outbox_entries, %i[service_type service_instance external_id],
              name: "index_outbox_entries_on_source_identity"
    add_index :outbox_entries, :observed_at
    add_index :outbox_entries, :observed_at,
              where: "status = 'pending'",
              name: "index_outbox_entries_pending_publication"
  end
end
