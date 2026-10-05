# frozen_string_literal: true

module Disappearance
  # The outcome of verifying a missing candidate directly against the
  # source: which disappearance state applies, the adapter's confidence in
  # that state, and optional extra provenance merged into the observation
  # payload (e.g. the HTTP status or lookup method that produced it).
  Finding = Struct.new(:state, :confidence, :detail, keyword_init: true) do
    def initialize(state:, confidence:, detail: nil)
      raise ArgumentError, "unknown disappearance state: #{state}" unless Disappearance::States::ALL.include?(state)

      super
    end
  end
end
