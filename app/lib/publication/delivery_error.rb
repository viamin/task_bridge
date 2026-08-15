# frozen_string_literal: true

module Publication
  # Raised when the HTTP layer fails in a way that prevents row-level result
  # parsing, or when a response cannot be reconciled with the submitted rows.
  #
  # retryable classifies the failure so callers can apply the retry policy
  # from RDR 215: transient transport errors retry with backoff; contract and
  # authentication failures are terminal until fixed.
  class DeliveryError < StandardError
    attr_reader :retryable

    def initialize(message, retryable:)
      super(message)
      @retryable = retryable
    end
  end
end
