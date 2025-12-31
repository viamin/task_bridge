# frozen_string_literal: true

require "ostruct"

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
