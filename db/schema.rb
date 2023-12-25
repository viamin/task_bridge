# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2023_12_25_084554) do
  create_table "sync_collections", force: :cascade do |t|
    t.string "title"
    t.datetime "last_synced"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "sync_items", force: :cascade do |t|
    t.boolean "completed"
    t.datetime "completed_at"
    t.datetime "completed_on"
    t.datetime "due_at"
    t.datetime "due_date"
    t.boolean "flagged"
    t.string "notes"
    t.datetime "start_at"
    t.datetime "start_date"
    t.string "status"
    t.string "title"
    t.string "item_type"
    t.string "type"
    t.string "url"
    t.string "external_id"
    t.datetime "last_modified"
    t.integer "parent_item_id"
    t.integer "sync_collection_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_item_id"], name: "index_sync_items_on_parent_item_id"
    t.index ["sync_collection_id"], name: "index_sync_items_on_sync_collection_id"
  end

  add_foreign_key "sync_items", "sync_collections"
  add_foreign_key "sync_items", "sync_items", column: "parent_item_id"
end
