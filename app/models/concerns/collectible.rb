# frozen_string_literal: true

module Collectible
  extend ActiveSupport::Concern

  included do
    belongs_to :sync_collection
  end
end
