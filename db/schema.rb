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

ActiveRecord::Schema[8.1].define(version: 2026_08_17_094249) do
  create_table "sync_collections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_synced"
    t.string "mapping_confidence"
    t.datetime "mapping_established_at"
    t.datetime "mapping_last_observed_at"
    t.text "mapping_metadata"
    t.string "mapping_method"
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "sync_items", force: :cascade do |t|
    t.boolean "completed"
    t.datetime "completed_at"
    t.datetime "completed_on"
    t.datetime "created_at", null: false
    t.datetime "due_at"
    t.datetime "due_date"
    t.string "external_id"
    t.datetime "first_observed_at"
    t.boolean "flagged"
    t.string "item_type"
    t.datetime "last_modified"
    t.datetime "last_observed_at"
    t.text "notes"
    t.integer "parent_item_id"
    t.datetime "source_created_at"
    t.string "source_external_id"
    t.text "source_metadata"
    t.string "source_service_instance"
    t.string "source_service_name"
    t.string "source_service_type"
    t.datetime "source_updated_at"
    t.string "source_url"
    t.datetime "start_at"
    t.datetime "start_date"
    t.string "status"
    t.integer "sync_collection_id"
    t.string "title"
    t.string "type"
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["last_modified"], name: "index_sync_items_on_last_modified"
    t.index ["parent_item_id"], name: "index_sync_items_on_parent_item_id"
    t.index ["sync_collection_id", "source_service_name"], name: "index_sync_items_on_collection_id_and_source_service_name", unique: true, where: "((sync_collection_id IS NOT NULL) AND (source_service_name IS NOT NULL))"
    t.index ["sync_collection_id"], name: "index_sync_items_on_sync_collection_id"
    t.index ["type", "source_service_name", "external_id"], name: "index_sync_items_on_type_service_name_and_external_id", unique: true
  end

  create_table "sync_service_states", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "detail"
    t.integer "items_synced", default: 0, null: false
    t.datetime "last_attempted_at"
    t.datetime "last_failed_at"
    t.datetime "last_successful_at"
    t.string "service_name", null: false
    t.string "status"
    t.datetime "updated_at", null: false
    t.index ["last_successful_at"], name: "index_sync_service_states_on_last_successful_at"
    t.index ["service_name"], name: "index_sync_service_states_on_service_name", unique: true
  end

  add_foreign_key "sync_items", "sync_collections"
  add_foreign_key "sync_items", "sync_items", column: "parent_item_id"
end
