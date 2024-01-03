# frozen_string_literal: true

class CreateSyncItems < ActiveRecord::Migration[7.1]
  def change
    create_table :sync_items do |t|
      t.boolean :completed
      t.datetime :completed_at
      t.datetime :completed_on
      t.datetime :due_at
      t.datetime :due_date
      t.boolean :flagged
      t.string :notes
      t.datetime :start_at
      t.datetime :start_date
      t.string :status
      t.string :title
      t.string :item_type
      t.string :type
      t.string :url
      t.string :external_id
      t.datetime :last_modified

      t.references :parent_item, null: true, foreign_key: {to_table: :sync_items}
      t.references :sync_collection, null: true, foreign_key: true

      t.timestamps
    end
  end
end
