# frozen_string_literal: true

module Debug
  def debug(message, debug_option = ENV.fetch("DEBUG", false))
    return unless debug_option

    puts "#{caller_locations(1, 1)}: #{message}"
  end
end
