# frozen_string_literal: true

module Outbox
  class WebPublisher
    # Resolves TaskBridge Web publication settings (RDR #215, issue #221)
    # from `task_bridge.web` in config/settings.yml, overridable through
    # Chamber's TASK_BRIDGE_WEB_* environment variables (see .env.example)
    # or through an 1Password `op://` reference resolved by `op-cache` in
    # the deployment's local scripts. Publication is disabled by default so
    # sync behavior is unchanged until a deployment opts in.
    class Config
      DEFAULT_BATCH_SIZE = 100
      DEFAULT_TIMEOUT_SECONDS = 30

      def self.resolve(overrides = {})
        settings = (Chamber.dig(:task_bridge, :web) || {}).stringify_keys
        new(settings.merge(overrides))
      end

      def initialize(settings = {})
        @settings = settings.stringify_keys
      end

      def enabled?
        settings.fetch("enabled", false)
      end

      def dry_run?
        settings.fetch("dry_run", false)
      end

      def base_url
        settings["base_url"].presence&.strip
      end

      def api_key
        settings["api_key"].presence
      end

      def batch_size
        settings.fetch("batch_size", DEFAULT_BATCH_SIZE).to_i.clamp(1..)
      end

      def timeout_seconds
        settings.fetch("timeout_seconds", DEFAULT_TIMEOUT_SECONDS).to_i.clamp(1..)
      end

      # Whether a run is enabled but cannot send: surface this to the
      # operator instead of silently skipping publication. Dry runs send
      # nothing, so they need no credentials and stay runnable.
      def incomplete?
        enabled? && !dry_run? && !complete?
      end

      def uri
        return @uri if defined?(@uri)

        parsed = URI.parse(base_url.to_s)
        @uri = parsed.is_a?(URI::HTTP) || parsed.is_a?(URI::HTTPS) ? parsed : nil
      rescue URI::InvalidURIError
        @uri = nil
      end

      private

      attr_reader :settings

      def complete?
        base_url.present? && api_key.present? && uri.present?
      end
    end
  end
end
