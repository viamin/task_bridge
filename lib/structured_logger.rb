# frozen_string_literal: true

class StructuredLogger
  def initialize(options)
    @log_file = File.expand_path(File.join(__dir__, "..", "log", options[:log_file]))
    @space_needed = options[:services].map(&:length).max + 1
    @existing_logs = if File.exist?(@log_file)
      JSON.parse(File.read(@log_file))
    else
      []
    end
  end

  def sync_data_for(service_name)
    @existing_logs.find { |log_hash| log_hash["service"] == service_name }
  end

  def last_synced(service_name, interval: false)
    last_sync = Chronic.parse(sync_data_for(service_name)["last_successful"])
    if interval
      Time.now - last_sync
    else
      last_sync
    end
  end

  def print_logs
    puts format("%-#{@space_needed}s |   Last Attempted   |   Last Successful  | Items Synced", "Service")
    puts "#{'-' * @space_needed}-|#{'-' * 20}|#{'-' * 20}|#{'-' * 13}"
    @existing_logs.each do |log_hash|
      puts format("%-#{@space_needed}s | %18s | %18s | %12d", log_hash["service"], log_hash["last_attempted"] || "", log_hash["last_successful"] || "", log_hash["items_synced"] || 0)
    end
  end

  def save_service_log!(service_logs)
    return if service_logs.nil?

    output = service_logs.map do |service_log|
      existing_index = @existing_logs.find_index { |hash| hash["service"] == service_log["service"] }
      if existing_index
        service_log.reverse_merge(@existing_logs.delete_at(existing_index))
      else
        service_log
      end
    end
    output += @existing_logs
    output.sort_by! { |element| element["service"] }
    File.write(@log_file, output.to_json)
    @existing_logs = output
  end
end
