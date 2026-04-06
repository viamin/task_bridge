# frozen_string_literal: true

# == Schema Information
#
# Table name: sync_collections
#
#  id          :integer          not null, primary key
#  last_synced :datetime
#  title       :string
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
class SyncCollection < ApplicationRecord
  has_many :sync_items, class_name: "Base::SyncItem", foreign_key: :sync_collection_id,
                        dependent: :nullify, inverse_of: :sync_collection

  def items
    sync_items.to_a
  end

  def <<(sync_item)
    sync_item.sync_collection_id = id
    sync_item.save!
  end

  def needs_sync?
    return true if last_synced.nil?

    sync_items.where.not(last_modified: nil).where("last_modified > ?", last_synced).exists?
  end
end
