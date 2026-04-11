# frozen_string_literal: true

module Collectible
  extend ActiveSupport::Concern

  included do
    belongs_to :sync_collection, optional: true, inverse_of: :sync_items
  end
end
