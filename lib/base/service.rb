# frozen_string_literal: true

module Base
  class Service
    prepend MemoWise
    include Debug

    attr_reader :options

    def initialize(options:)
      @options = options
      @last_sync_data = options[:logger].sync_data_for(friendly_name)
    end

    def friendly_name
      raise "not implemented"
    end

    def should_sync?(item_updated_at = nil)
      time_since_last_sync = options[:logger].last_synced(friendly_name, interval: item_updated_at.nil?)
      return true if time_since_last_sync.nil?

      if item_updated_at.present?
        time_since_last_sync < item_updated_at
      else
        time_since_last_sync > min_sync_interval
      end
    end

    private

    # the default minimum time we should wait between syncing items
    def min_sync_interval
      15.minutes.to_i
    end
  end
end
