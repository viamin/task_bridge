# frozen_string_literal: true

module Base
  module AppleScriptLoader
    private

    def ensure_appscript_loaded!
      return if defined?(Appscript)

      raise LoadError, "Appscript is only supported on macOS" unless RUBY_PLATFORM.include?("darwin")

      begin
        require "rb-scpt"
      rescue LoadError, TypeError => e
        raise LoadError, "Unable to load rb-scpt: #{e.message}"
      end
    end
  end
end
