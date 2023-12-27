require "optparse"

namespace :task_bridge do
  desc "sync all services"
  task sync: :environment do
    include Debug
    @options = {
      primary: Chamber.dig!(:task_bridge, :primary_service),
      tags: Chamber.dig!(:task_bridge, :sync, :tags),
      personal_tags: Chamber.dig(:task_bridge, :personal_tags),
      work_tags: Chamber.dig(:task_bridge, :work_tags),
      services: Chamber.dig!(:task_bridge, :sync, :services),
      list: Chamber.dig(:google, :tasks_list),
      repositories: Chamber.dig(:github, :repositories)&.split(","),
      reminders_mapping: Chamber.dig(:reminders, :list_mapping),
      max_age: Chamber.dig!(:task_bridge, :sync, :max_age).to_i,
      update_ids_for_existing: Chamber.dig!(:task_bridge, :update_ids_for_existing_items),
      delete: Chamber.dig!(:task_bridge, :delete_completed),
      only_from_primary: false,
      only_to_primary: false,
      pretend: false,
      quiet: false,
      force: false,
      verbose: false,
      log_file: Chamber.dig!(:task_bridge, :log_file),
      debug: Chamber.dig!(:task_bridge, :debug),
      console: false,
      history: false,
      testing: false
    }
    o = OptionParser.new
    supported_services = Chamber.dig!(:task_bridge, :all_supported_services)
    o.banner = "Sync Tasks from one service to another\nSupported services: #{supported_services.join(", ")}\nBy default, tasks found with the tags in --tags will have a work context"
    o.on("-p", "--primary", "Primary task service") { |value| @options[:primary] = value }
    o.on("-t", "--tags", "Tags (or labels) to sync") { |value| @options[:tags] = value }
    o.on("-e", "--peronsal-tags", "Tags (or labels) used for personal context") { |value| @options[:personal_tags] = value }
    o.on("-w", "--work-tags", "Tags (or labels) used for work context (overrides personal tags)") { |value| @options[:work_tags] = value }
    o.on("-s", "--services", "Services to sync tasks among") { |value| @options[:services] = value }
    o.on("-l", "--list", "Task list name to sync to") { |value| @options[:list] = value }
    o.on("-r", "--repositories", "Github repositories to sync from") { |value| @options[:repositories] = value }
    o.on("-m", "--reminders-mapping", "Reminder lists to map to primary service lists/projects") { |value| @options[:reminders_mapping] = value }
    o.on("-a", "--max-age", Integer, "Skip syncing asks that have not been modified within this time (0 to disable)") { |value| @options[:max_age] = value }
    o.on("-u", "--update-ids-for-existing", "Update Sync IDs for already synced items") { |value| @options[:update_ids_for_existing] = value }
    o.on("-d", "--delete", "Delete completed tasks on service") { |value| @options[:delete] = value }
    o.on("-o", "--only-from-primary", "Only sync FROM the primary service") { |value| @options[:only_from_primary] = value }
    o.on("-n", "--only-to-primary", "Only sync TO the primary service") { |value| @options[:only_to_primary] = value }
    o.on("--pretend", "List the found tasks, don't sync") { |value| @options[:pretend] = value }
    o.on("-q", "--quiet", "No output - except a 'finished sync' with timestamp") { |value| @options[:quiet] = value }
    o.on("-f", "--force", "Ignore minimum sync interval") { |value| @options[:force] = value }
    o.on("-v", "--verbose", "Verbose output") { |value| @options[:verbose] = value }
    o.on("-g", "--log-file", "File name for service log") { |value| @options[:log_file] = value }
    o.on("--debug", "Print debug output") { |value| @options[:debug] = value }
    o.on("-c", "--console", "Run live console session") { |value| @options[:console] = value }
    o.on("-h", "--history", "Print sync service history") { |value| @options[:history] = value }
    o.on("--testing", "For testing purposes only") { |value| @options[:testing] = value }
    # o.require_exact = true
    args = o.order!(ARGV)
    o.parse!(args)

    raise "Supported services: #{supported_services.join(", ")}" unless supported_services.intersect?(@options[:services])

    @options[:max_age_timestamp] = (@options[:max_age]).zero? ? nil : Chronic.parse("#{@options[:max_age]} ago")
    @options[:uses_personal_tags] = @options[:work_tags].blank?
    @options[:sync_started_at] = Time.now.strftime("%Y-%m-%d %I:%M%p")
    @options[:logger] = StructuredLogger.new(@options)
    @primary_service = "#{@options[:primary]}::Service".safe_constantize.new(options: @options)
    @options[:primary_service] = @primary_service
    @services = @options[:services].to_h { |s| [s, "#{s}::Service".safe_constantize.new(options: @options)] }
    start_time = Time.now
    puts "Starting sync at #{@options[:sync_started_at]}" unless @options[:quiet]
    puts @options.pretty_inspect if @options[:debug]
    return @options[:logger].print_logs if @options[:history]
    return testing if @options[:testing]
    return console if @options[:console]

    @services.each_value do |service|
      @service_logs = []
      if service.respond_to?(:authorized) && service.authorized == false
        @service_logs << {service: service.friendly_name, last_attempted: @options[:sync_started_at]}.stringify_keys
      elsif @options[:delete]
        service.prune if service.respond_to?(:prune)
      elsif @options[:only_to_primary] && service.sync_strategies.include?(:to_primary)
        @service_logs << service.sync_to_primary(@primary_service)
      elsif @options[:only_from_primary] && service.sync_strategies.include?(:from_primary)
        @service_logs << service.sync_from_primary(@primary_service)
      elsif service.sync_strategies.include?(:two_way)
        # if the #sync_with_primary method exists, we should use it unless options force us not to
        @service_logs << service.sync_with_primary(@primary_service)
      else
        # Generally we should sync FROM the primary service first, since it should be the source of truth
        # and we want to avoid overwriting anything in the primary service if a duplicate task exists
        @service_logs << service.sync_from_primary(@primary_service) if service.sync_strategies.include?(:from_primary)
        @service_logs << service.sync_to_primary(@primary_service) if service.sync_strategies.include?(:to_primary)
      end
      @options[:logger].save_service_log!(@service_logs)
    end
    end_time = Time.now
    return if @options[:quiet]

    puts "Finished sync at #{end_time.strftime("%Y-%m-%d %I:%M%p")}"
    puts "Sync took #{end_time - start_time} seconds"
  end
end
