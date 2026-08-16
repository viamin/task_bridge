# frozen_string_literal: true

class CreatePublicationOutboxEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :publication_outbox_entries do |t|
      # Contract identity
      t.string  :idempotency_key, null: false
      t.string  :record_kind,     null: false

      # Serialized canonical payload (JSON); immutable across retries per contract rules.
      t.text    :payload, null: false

      # Delivery lifecycle
      t.string  :status,      null: false, default: "pending"
      t.integer :retry_count, null: false, default: 0
      t.text    :error_message

      # Source provenance for filtering and replay
      t.string   :service_type, null: false
      t.string   :service_instance, null: false
      t.datetime :observed_at, null: false, precision: 6

      # Delivery timestamps
      t.datetime :delivered_at, precision: 6
      t.datetime :failed_at, precision: 6

      t.timestamps
    end

    add_index :publication_outbox_entries, :idempotency_key, unique: true
    # Status + observed_at + id supports fetching publishable rows oldest-first.
    add_index :publication_outbox_entries, %i[status observed_at id], name: "idx_pub_outbox_on_status_observed_at_id"
    add_index :publication_outbox_entries, %i[service_instance status]
  end
end
