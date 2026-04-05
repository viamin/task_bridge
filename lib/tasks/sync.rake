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
    o.on("-p", "--primary [PRIMARY]", "Primary task service") { |value| overrides[:primary] = value }
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
    o.on("-h", "--history", "Print sync service history") do
      StructuredLogger.new(log_file: overrides[:log_file], services: overrides[:services]).print_logs
      exit
    end
    # o.require_exact = true
    args = o.order!(ARGV)
    o.parse!(args)
    self.options = overrides

    unsupported_services = options[:services] - supported_services
    raise "Supported services: #{supported_services.join(', ')}" if unsupported_services.any?

    options[:max_age_timestamp] = options[:max_age].zero? ? nil : Chronic.parse("#{options[:max_age]} ago")
    options[:uses_personal_tags] = options[:work_tags].blank?
    options[:sync_started_at] = Time.now.strftime("%Y-%m-%d %I:%M%p")
    options[:logger] = StructuredLogger.new(options)
    @primary_service = "#{options[:primary]}::Service".safe_constantize.new
    options[:primary_service] = @primary_service
    @services = options[:services].to_h { |s| [s, "#{s}::Service".safe_constantize.new] }
    start_time = Time.now
    puts "Starting sync at #{options[:sync_started_at]}" unless options[:quiet]
    puts options.pretty_inspect if options[:debug]

    items_by_service = {}
    progressbar = ProgressBar.create(format: " %c/%C |%w>%i| %e ", total: @services.length)
    @services.each do |service_name, service|
      if service.respond_to?(:authorized) && service.authorized == false
        progressbar.log "Skipping unauthorized service #{service.friendly_name}"
        progressbar.increment
        next
      end
      progressbar.log "Gathering items from #{service.friendly_name}"
      # Reuse these loaded items during the later service syncs so title grouping
      # does not trigger a second full remote scan for the same collection.
      items_by_service[service_name.to_sym] = service.items_to_sync(tags: options[:tags])
      progressbar.increment
    end

    # Group items into sync collections. All services return Base::SyncItem
    # subclasses (e.g., Asana::Task, GoogleTasks::Task), so they all respond to
    # sync_collection_id, title, and incomplete?.
    items_by_collection = items_by_service.values.flatten.group_by(&:sync_collection_id)
    ungrouped_items = items_by_collection.delete(nil) || []
    # group the remaining items by title
    ungrouped_items_by_title = ungrouped_items.group_by(&:title)
    # for each group, create a sync collection if the statuses match
    ungrouped_items_by_title.each do |title, items|
      providers = items.map(&:provider)
      next unless items.count > 1 &&
                  items.any?(&:incomplete?) &&
                  providers.uniq.count == items.count &&
                  items.count <= items_by_service.keys.length

      collection = SyncCollection.create(title:)
      items.each { |item| collection << item }
      items_by_collection[collection.id] = items
    end
    @services.each do |service_name, service|
      @service_logs = []
      service_items = items_by_service[service_name.to_sym] || []
      begin
        if service.respond_to?(:authorized) && service.authorized == false
          @service_logs << { service: service.friendly_name, last_attempted: options[:sync_started_at] }.stringify_keys
        elsif options[:delete]
          service.prune if service.respond_to?(:prune)
        elsif options[:only_to_primary] && service.sync_strategies.include?(:to_primary)
          @service_logs << service.sync_to_primary(@primary_service, service_items:)
        elsif options[:only_from_primary] && service.sync_strategies.include?(:from_primary)
          @service_logs << service.sync_from_primary(@primary_service, service_items:)
        elsif service.sync_strategies.include?(:two_way)
          # if the #sync_with_primary method exists, we should use it unless options force us not to
          @service_logs << service.sync_with_primary(@primary_service, service_items:)
        else
          # Keep each service isolated so one transient failure does not abort the full sync run.
          # Generally we should sync FROM the primary service first, since it should be the source of truth
          # and we want to avoid overwriting anything in the primary service if a duplicate task exists
          @service_logs << service.sync_from_primary(@primary_service, service_items:) if service.sync_strategies.include?(:from_primary)
          @service_logs << service.sync_to_primary(@primary_service, service_items:) if service.sync_strategies.include?(:to_primary)
        end
      rescue StandardError => e
        @service_logs << {
          service: service.friendly_name,
          status: "failed",
          last_attempted: options[:sync_started_at],
          last_failed: Time.now.strftime("%Y-%m-%d %I:%M%p"),
          items_synced: 0,
          error_class: e.class.name,
          error_message: e.message
        }.stringify_keys
        warn "Sync failed for #{service.friendly_name}: #{e.class} #{e.message}" unless options[:quiet]
      end
      options[:logger].save_service_log!(@service_logs)
      next if @service_logs.any? { |log| log["status"] == "failed" }

      service_items.filter_map(&:sync_collection_id).uniq.each do |collection_id|
        SyncCollection.find_by(id: collection_id)&.update(last_synced: Time.current)
      end
    end
    end_time = Time.now
    return if options[:quiet]

    puts "Finished sync at #{end_time.strftime('%Y-%m-%d %I:%M%p')}"
    puts "Sync took #{end_time - start_time} seconds"
  end
end
