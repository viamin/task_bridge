# frozen_string_literal: true

# == Schema Information
#
# Table name: sync_collections
#
#  id                       :integer          not null, primary key
#  last_synced              :datetime
#  mapping_confidence       :string
#  mapping_established_at   :datetime
#  mapping_last_observed_at :datetime
#  mapping_metadata         :text
#  mapping_method           :string
#  title                    :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#
class SyncCollection < ApplicationRecord
  has_many :sync_items, class_name: "Base::SyncItem", foreign_key: :sync_collection_id,
                        dependent: :nullify, inverse_of: :sync_collection

  serialize :mapping_metadata, coder: JSON

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

  def update_mapping_provenance!(method:, confidence:, metadata: {}, observed_at: Time.current)
    override_mapping = mapping_method.nil? ||
                       SyncMappingProvenance.method_priority(method) >=
                       SyncMappingProvenance.method_priority(mapping_method)
    self.mapping_method = method if override_mapping
    self.mapping_confidence = confidence if override_mapping
    self.mapping_metadata = if override_mapping
      (mapping_metadata || {}).merge(metadata.deep_stringify_keys)
    else
      mapping_metadata
    end
    self.mapping_established_at ||= created_at || observed_at
    self.mapping_last_observed_at = observed_at
    save! if changed?
    self
  end
end
