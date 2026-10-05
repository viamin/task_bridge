# frozen_string_literal: true

module Outbox
  # Outbox publication is bookkeeping around sync flows (#219): a failed
  # outbox write must never change the sync result that produced it. This
  # wrapper isolates database write failures behind a bounded retry with
  # backoff (transient failures such as a busy SQLite lock), reports
  # whatever still fails, and returns nil instead of raising so callers
  # such as Base::SyncItem#refresh_from_external! and
  # Base::Service#persist_sync_collection_for keep their pre-outbox
  # semantics. Emitters advance their diff baseline only after every row
  # is enqueued, so an abandoned write is re-detected (at-least-once) by
  # the next sync run rather than lost.
  module IsolatedWrite
    # Transient infrastructure failures worth burning a retry on. SQLite
    # busy/locked errors surface as StatementInvalid.
    RETRYABLE_ERRORS = [
      ActiveRecord::ConnectionTimeoutError,
      ActiveRecord::StatementInvalid
    ].freeze
    # StatementInvalid subclasses that are not transient (the database
    # file itself is missing) must not burn retries.
    NON_RETRYABLE_ERRORS = [ActiveRecord::NoDatabaseError].freeze
    DEFAULT_RETRY_DELAYS = [0.05, 0.1, 0.2].freeze

    module_function

    def call(description, retry_delays: DEFAULT_RETRY_DELAYS)
      attempts = 0
      begin
        yield
      rescue ActiveRecord::ActiveRecordError => e
        attempts += 1
        if retryable?(e) && attempts <= retry_delays.length
          warn "[Outbox] retrying #{description} (attempt #{attempts}/#{retry_delays.length}) after #{e.class}: #{e.message}"
          sleep(retry_delays[attempts - 1])
          retry
        end
        warn "[Outbox] dropping #{description}, the next sync run re-detects it (#{e.class}: #{e.message})"
        nil
      end
    end

    def retryable?(error)
      NON_RETRYABLE_ERRORS.none? { |error_class| error.is_a?(error_class) } &&
        RETRYABLE_ERRORS.any? { |error_class| error.is_a?(error_class) }
    end
  end
end
