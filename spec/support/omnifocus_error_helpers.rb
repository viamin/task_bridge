# frozen_string_literal: true

require "ostruct"

# Stub Appscript module when rb-scpt gem is not available (non-macOS platforms)
unless defined?(Appscript)
  module Appscript
    class Reference # :nodoc:
      # Minimal stub for Appscript::Reference on non-macOS platforms.
      # The real class wraps AppleScript object specifiers; tests only
      # need the type to exist so rescue clauses and type checks work.
      def get
        :missing_value
      end
    end
    CommandError = Class.new(StandardError) do
      attr_reader :reference, :command_name, :parameters, :real_error, :error_info

      def initialize(reference = nil, command_name = nil, parameters = nil, real_error = nil, error_info = nil) # rubocop:disable Metrics/ParameterLists
        @reference = reference
        @command_name = command_name
        @parameters = parameters
        @real_error = real_error
        @error_info = error_info
        super(real_error.to_s)
      end

      def to_i
        @real_error.respond_to?(:to_i) ? @real_error.to_i : 0
      end
    end
    ApplicationNotFoundError = Class.new(StandardError) do
      def initialize(_url = nil, _desc = nil, name = nil)
        super("Application #{name} not found")
      end
    end

    def self.app(*_args)
      nil
    end
  end
end

# Helper methods for creating mock AppleScript errors in tests
module OmnifocusErrorHelpers
  # Creates an Appscript::CommandError that simulates OSERROR -600
  # "Application isn't running"
  def make_app_not_running_error(command: "get", reference: 'app("/Applications/OmniFocus.app")')
    mock_error = OpenStruct.new(
      to_i: -600,
      to_s: "Application isn't running."
    )
    Appscript::CommandError.new(reference, command, {}, mock_error, nil)
  end

  # Creates an Appscript::CommandError that simulates OSERROR -609
  # "Connection is invalid"
  def make_connection_invalid_error(command: "get", reference: 'app("/Applications/OmniFocus.app")')
    mock_error = OpenStruct.new(
      to_i: -609,
      to_s: "Connection is invalid."
    )
    Appscript::CommandError.new(reference, command, {}, mock_error, nil)
  end

  # Creates an Appscript::CommandError that simulates OSERROR -1708
  # "Event wasn't handled"
  def make_event_not_handled_error(command: "get", reference: 'app("/Applications/OmniFocus.app")')
    mock_error = OpenStruct.new(
      to_i: -1708,
      to_s: "The event wasn't handled."
    )
    Appscript::CommandError.new(reference, command, {}, mock_error, nil)
  end

  # Creates an Appscript::ApplicationNotFoundError
  def make_app_not_found_error(name: "Omnifocus")
    Appscript::ApplicationNotFoundError.new(nil, nil, name)
  end
end

RSpec.configure do |config|
  config.include OmnifocusErrorHelpers
end
