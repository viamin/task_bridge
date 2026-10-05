# frozen_string_literal: true

module Disappearance
  # How an adapter may infer that a previously observed item disappeared
  # from its source (#220). Strategies are deliberately conservative: a mode
  # is only enabled when the source's fetch semantics make absence
  # meaningful. Per-adapter choices and their rationale are documented in
  # docs/source-deletion-detection.md.
  class Strategy
    MODES = %i[disabled full_list_absence filtered_with_verification].freeze

    attr_reader :mode, :state, :confidence, :detected_by

    def initialize(mode:, state: nil, confidence: nil, detected_by: nil)
      raise ArgumentError, "unknown detection mode: #{mode}" unless MODES.include?(mode)

      @mode = mode
      @state = state
      @confidence = confidence
      @detected_by = detected_by
    end

    def disabled?
      mode == :disabled
    end

    def full_list_absence?
      mode == :full_list_absence
    end

    class << self
      # Absence from the adapter's fetch proves nothing (filtered,
      # incremental, or limit-windowed queries and no way to verify by
      # lookup). The default for adapters without safe detection semantics.
      def disabled
        new(mode: :disabled)
      end

      # The adapter's canonical fetch enumerates every item TaskBridge
      # tracks for the source, so absence after a successful complete fetch
      # is the disappearance signal itself.
      def full_list_absence(state:, confidence:)
        new(mode: :full_list_absence, state:, confidence:, detected_by: "missing_from_full_list")
      end

      # Absence proves nothing by itself, but the adapter verifies each
      # candidate by direct source lookup (#verify_missing_item) and only a
      # conclusive verification becomes a tombstone.
      def filtered_with_verification
        new(mode: :filtered_with_verification, detected_by: "direct_source_lookup")
      end
    end
  end
end
