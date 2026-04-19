# frozen_string_literal: true

module Collectible
  extend ActiveSupport::Concern

  included do
    # belongs_to :sync_collection is already declared in Base::SyncItem.
    # This concern exists for future per-service collection customization.
  end
end
