# frozen_string_literal: true

module Outbox
  # Prunes the local outbox past its retention windows
  # (task_bridge.outbox.retention in config/settings.yml). TaskBridge Web owns
  # durable history (RDR #215), so the outbox is a bounded queue, not an
  # archive: delivered rows prune after `delivered_days` and terminal failures
  # after the longer `failed_days` operator-review window. Pending rows are
  # never pruned — they are still awaiting publication.
  class Prune
    DEFAULT_DELIVERED_DAYS = 7
    DEFAULT_FAILED_DAYS = 30

    def self.run!(now: Time.current)
      new(now:).run!
    end

    def initialize(now: Time.current)
      @now = now
    end

    def run!
      { delivered: prune_delivered, failed: prune_failed }
    end

    private

    attr_reader :now

    def prune_delivered
      delivered_cutoff = now - delivered_days.days
      OutboxEntry.delivered
                 .where(published_at: ..delivered_cutoff)
                 .or(OutboxEntry.delivered.where(updated_at: ..delivered_cutoff))
                 .delete_all
    end

    def prune_failed
      OutboxEntry.failed.where(updated_at: ..(now - failed_days.days)).delete_all
    end

    def delivered_days
      Chamber.dig(:task_bridge, :outbox, :retention, :delivered_days) || DEFAULT_DELIVERED_DAYS
    end

    def failed_days
      Chamber.dig(:task_bridge, :outbox, :retention, :failed_days) || DEFAULT_FAILED_DAYS
    end
  end
end
