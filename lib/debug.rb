# frozen_string_literal: true

module Debug
  def debug(message)
    puts "#{caller_locations(1, 1)}: #{message}"
  end
end
