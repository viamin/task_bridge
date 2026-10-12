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
        boolean_setting("enabled")
      end

      def dry_run?
        boolean_setting("dry_run")
      end

      def base_url
        string_setting("base_url")
      end

      def api_key
        string_setting("api_key")
      end

      def batch_size
        positive_integer_setting("batch_size", DEFAULT_BATCH_SIZE)
      end

      def timeout_seconds
        positive_integer_setting("timeout_seconds", DEFAULT_TIMEOUT_SECONDS)
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
        @uri = valid_http_uri?(parsed) ? parsed : nil
      rescue URI::InvalidURIError
        @uri = nil
      end

      private

      attr_reader :settings

      def complete?
        base_url.present? && api_key.present? && uri.present?
      end

      def valid_http_uri?(parsed)
        (parsed.is_a?(URI::HTTP) || parsed.is_a?(URI::HTTPS)) && parsed.host.present?
      end

      def boolean_setting(key)
        ActiveModel::Type::Boolean.new.cast(settings.fetch(key, false))
      end

      def string_setting(key)
        value = settings[key]
        value.strip.presence if value.is_a?(String)
      end

      def positive_integer_setting(key, default)
        value = integer_setting(settings[key])
        value ? value.clamp(1..) : default
      end

      def integer_setting(value)
        return value if value.is_a?(Integer)

        Integer(value, exception: false) if value.is_a?(String)
      end
    end
  end
end
