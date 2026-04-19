# frozen_string_literal: true

module Debug
  def debug(message, debug_option = Chamber.dig(:task_bridge, :debug))
    return unless debug_option

    puts "#{caller_locations(1, 1)}: #{message}"
  end
end
