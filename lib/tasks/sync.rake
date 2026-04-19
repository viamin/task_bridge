# frozen_string_literal: true

require "optparse"

namespace :task_bridge do
  desc "sync all services"
  task sync: :environment do
    extend Debug
    extend GlobalOptions

    overrides = options
    o = OptionParser.new
    supported_services = Chamber.dig!(:task_bridge, :all_supported_services)
    o.banner = "Sync Tasks from one service to another\nSupported services: #{supported_services.join(', ')}\nBy default, tasks found with the tags in --tags will have a work context"
    o.on("-p", "--primary [PRIMARY]", "Primary task service") do |value|
      overrides[:primary] = value
      overrides[:primary_service] = "#{value}::Service".safe_constantize
    end
    o.on("-t", "--tags [TAGS]", "Tags (or labels) to sync") { |value| overrides[:tags] = value.split(",") }
    o.on("-s", "--services [SERVICES]", String, "Services to sync tasks among") { |services| overrides[:services] = services.split(",") }
    o.on("-e", "--personal-tags [TAGS]", "Tags (or labels) used for personal context") { |value| overrides[:personal_tags] = value.split(",") }
    o.on("-w", "--work-tags [TAGS]", "Tags (or labels) used for work context (overrides personal tags)") { |value| overrides[:work_tags] = value.split(",") }
    o.on("-l", "--list [LIST]", "Task list name to sync to") { |value| overrides[:list] = value }
    o.on("-r", "--repositories [REPOSITORIES]", "Github repositories to sync from") { |value| overrides[:repositories] = value.split(",") }
    o.on("-m", "--reminders-mapping [MAPPING]", "Reminder lists to map to primary service lists/projects") { |value| overrides[:reminders_mapping] = value }
    o.on("-a", "--max-age [MAX_AGE]", Integer, "Skip syncing tasks that have not been modified within this time (0 to disable)") { |value| overrides[:max_age] = value }
    o.on("-u", "--update-ids-for-existing", "Update Sync IDs for already synced items") { overrides[:update_ids_for_existing] = true }
    o.on("-d", "--delete", "Delete completed tasks on service") { overrides[:delete] = true }
    o.on("-o", "--only-from-primary", "Only sync FROM the primary service") { overrides[:only_from_primary] = true }
    o.on("-n", "--only-to-primary", "Only sync TO the primary service") { overrides[:only_to_primary] = true }
    o.on("-x", "--pretend", "List the found tasks, don't sync") { overrides[:pretend] = true }
    o.on("-q", "--quiet", "No output - except a 'finished sync' with timestamp") { |value| overrides[:quiet] = value }
    o.on("-f", "--force", "Ignore minimum sync interval") { overrides[:force] = true }
    o.on("-v", "--verbose", "Verbose output") { overrides[:verbose] = true }
    o.on("-g", "--log-file [FILE]", "File name for service log") { |value| overrides[:log_file] = value }
    o.on("-b", "--debug", "Print debug output") { overrides[:debug] = true }
    o.on("--help", "Print available command line options") do
      puts o
      exit
    end
    o.on("-h", "--history", "Print sync service history") { overrides[:history] = true }
    # o.require_exact = true
    args = ARGV.drop_while { |arg| arg != "--" && !arg.start_with?("-") }
    args = args.drop(1) if args.first == "--"
    args = o.order!(args)
    o.parse!(args)
    self.options = overrides

    raise OptionParser::InvalidOption, "--only-from-primary and --only-to-primary are mutually exclusive" if options[:only_from_primary] && options[:only_to_primary]

    unsupported_services = options[:services] - supported_services
    raise "Supported services: #{supported_services.join(', ')}" if unsupported_services.any?

    if options[:history]
      StructuredLogger.new(log_file: options[:log_file], services: options[:services]).print_logs
      next
    end

    options[:max_age_timestamp] = options[:max_age].zero? ? nil : Chronic.parse("#{options[:max_age]} ago")
    options[:uses_personal_tags] = options[:work_tags].blank?
    options[:sync_started_at] = Time.current.utc.iso8601(6)
    options[:logger] = StructuredLogger.new(options)
    primary_service_reference = options[:primary_service] || "#{options[:primary]}::Service".safe_constantize
    raise "Unknown primary service: #{options[:primary]}" unless primary_service_reference

    @primary_service = primary_service_reference.is_a?(Class) ? primary_service_reference.new : primary_service_reference
    options[:primary_service] = @primary_service
    @services = options[:services].to_h do |service_name|
      service_class = "#{service_name}::Service".safe_constantize
      raise "Unknown service: #{service_name}" unless service_class

      [service_name, service_class.new]
    end
    start_time = Time.current
    failed_services = false
    puts "Starting sync at #{options[:sync_started_at]}" unless options[:quiet]
    puts options.pretty_inspect if options[:debug]

    @services.each_value do |service|
      @service_logs = []
      begin
        if service.respond_to?(:authorized) && service.authorized == false
          @service_logs << { service: service.friendly_name, last_attempted: options[:sync_started_at] }.stringify_keys
        elsif options[:delete]
          service.prune if service.respond_to?(:prune)
          @service_logs << {
            service: service.friendly_name,
            last_attempted: options[:sync_started_at],
            last_successful: options[:sync_started_at],
            items_synced: 0,
            detail: "Pruned completed items"
          }.stringify_keys
        elsif options[:only_to_primary] && service.sync_strategies.include?(:to_primary)
          @service_logs << if service.should_sync?
            service_items = service.items_to_sync(tags: options[:tags], only_modified_dates: true)
            service.sync_to_primary(@primary_service, service_items:)
          else
            service.sync_to_primary(@primary_service)
          end
        elsif options[:only_from_primary] && service.sync_strategies.include?(:from_primary)
          @service_logs << if service.should_sync?
            service_items = service.items_to_sync(tags: options[:tags])
            service.sync_from_primary(@primary_service, service_items:)
          else
            service.sync_from_primary(@primary_service)
          end
        elsif service.sync_strategies.include?(:two_way)
          # if the #sync_with_primary method exists, we should use it unless options force us not to
          @service_logs << if service.should_sync?
            service_items = service.items_to_sync(tags: options[:tags])
            service.sync_with_primary(@primary_service, service_items:)
          else
            service.sync_with_primary(@primary_service)
          end
        elsif service.should_sync?
          # Keep each service isolated so one transient failure does not abort the full sync run.
          # Generally we should sync FROM the primary service first, since it should be the source of truth
          # and we want to avoid overwriting anything in the primary service if a duplicate task exists
          from_primary_items = service.items_to_sync(tags: options[:tags]) if service.sync_strategies.include?(:from_primary)
          to_primary_items = service.items_to_sync(tags: options[:tags], only_modified_dates: true) if service.sync_strategies.include?(:to_primary)
          @service_logs << service.sync_from_primary(@primary_service, service_items: from_primary_items) if service.sync_strategies.include?(:from_primary)
          @service_logs << service.sync_to_primary(@primary_service, service_items: to_primary_items) if service.sync_strategies.include?(:to_primary)
        else
          @service_logs << service.sync_from_primary(@primary_service) if service.sync_strategies.include?(:from_primary)
          @service_logs << service.sync_to_primary(@primary_service) if service.sync_strategies.include?(:to_primary)
        end
      rescue StandardError => e
        failed_services = true
        @service_logs << {
          service: service.friendly_name,
          status: "failed",
          last_attempted: options[:sync_started_at],
          last_failed: Time.current.utc.iso8601(6),
          items_synced: 0,
          error_class: e.class.name,
          error_message: e.message
        }.stringify_keys
        warn "Sync failed for #{service.friendly_name}: #{e.class} #{e.message}" unless options[:quiet]
      end
      options[:logger].save_service_log!(@service_logs)
      SyncServiceState.record_summary!(
        options[:logger].summarize_service_run(service_name: service.friendly_name, logs: @service_logs)
      )
      next if @service_logs.any? { |log| log["status"] == "failed" }

      touched_collection_ids = @service_logs.flat_map do |log|
        Array(log["touched_collection_ids"] || log[:touched_collection_ids])
      end
      touched_collection_ids.uniq.each do |collection_id|
        SyncCollection.find_by(id: collection_id)&.update(last_synced: Time.current)
      end
    end
    end_time = Time.current
    unless options[:quiet]
      puts "Finished sync at #{end_time.utc.iso8601(6)}"
      puts "Sync took #{end_time - start_time} seconds"
    end

    exit 1 if failed_services
  end
end
