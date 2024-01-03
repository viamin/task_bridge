# frozen_string_literal: true

require "optparse"

namespace :task_bridge do
  desc "sync all services"
  task sync: :environment do
    include Debug
    include GlobalOptions

    overrides = options
    o = OptionParser.new
    supported_services = Chamber.dig!(:task_bridge, :all_supported_services)
    o.banner = "Sync Tasks from one service to another\nSupported services: #{supported_services.join(", ")}\nBy default, tasks found with the tags in --tags will have a work context"
    o.on("-p", "--primary [PRIMARY]", "Primary task service") { |value| overrides[:primary] = value }
    o.on("-t", "--tags [TAGS]", "Tags (or labels) to sync") { |value| overrides[:tags] = value }
    o.on("-s", "--services [SERVICES]", String, "Services to sync tasks among") { |services| overrides[:services] = services.split(",") }
    o.on("-e", "--personal-tags [TAGS]", "Tags (or labels) used for personal context") { |value| overrides[:personal_tags] = value }
    o.on("-w", "--work-tags [TAGS]", "Tags (or labels) used for work context (overrides personal tags)") { |value| overrides[:work_tags] = value }
    o.on("-l", "--list [LIST]", "Task list name to sync to") { |value| overrides[:list] = value }
    o.on("-r", "--repositories [REPOSITORIES]", "Github repositories to sync from") { |value| overrides[:repositories] = value }
    o.on("-m", "--reminders-mapping [MAPPING]", "Reminder lists to map to primary service lists/projects") { |value| overrides[:reminders_mapping] = value }
    o.on("-a", "--max-age [MAX_AGE]", Integer, "Skip syncing asks that have not been modified within this time (0 to disable)") { |value| overrides[:max_age] = value }
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
    o.on("-h", "--history", "Print sync service history") do
      StructuredLogger.new(log_file: overrides[:log_file], service_names: overrides[:services]).print_logs
      exit
    end
    # o.require_exact = true
    args = o.order!(ARGV)
    o.parse!(args)
    options = overrides

    raise "Supported services: #{supported_services.join(", ")}" unless supported_services.intersect?(options[:services])

    options[:max_age_timestamp] = (options[:max_age]).zero? ? nil : Chronic.parse("#{options[:max_age]} ago")
    options[:uses_personal_tags] = options[:work_tags].blank?
    options[:sync_started_at] = Time.now.strftime("%Y-%m-%d %I:%M%p")
    options[:logger] = StructuredLogger.new(log_file: options[:log_file], service_names: options[:services])
    @primary_service = "#{options[:primary]}::Service".safe_constantize.new
    options[:primary_service] = @primary_service
    @services = options[:services].to_h { |s| [s, "#{s}::Service".safe_constantize.new] }
    start_time = Time.now
    puts "Starting sync at #{options[:sync_started_at]}" unless options[:quiet]
    puts options.pretty_inspect if options[:debug]

    items_by_service = {}
    progressbar = ProgressBar.create(format: " %c/%C |%w>%i| %e ", total: @services.length)
    @services.each do |service_name, service|
      progressbar.log "Gathering items from #{service.friendly_name}"
      items_by_service[service_name.to_sym] = service.items_to_sync(tags: options[:tags], only_modified_dates: true)
      progressbar.increment
    end

    # group items into sync collections
    items_by_collection = items_by_service.values.flatten.group_by(&:sync_collection_id)
    ungrouped_items = items_by_collection.delete(nil)
    # group the remaining items by title
    ungrouped_items_by_title = ungrouped_items.group_by(&:title)
    # for each group, create a sync collection if the statuses match
    ungrouped_items_by_title.each do |title, items|
      if items.any?(&:incomplete?) && (items.count <= items_by_service.keys.length)
        collection = SyncCollection.create(title:)
        items.each { |item| collection << item }
        items_by_collection[collection.id] = collection
      end
    end
    binding.pry

    # @services.each_value do |service|
    #   @service_logs = []
    #   if service.respond_to?(:authorized) && service.authorized == false
    #     @service_logs << {service: service.friendly_name, last_attempted: options[:sync_started_at]}.stringify_keys
    #   elsif options[:delete]
    #     service.prune if service.respond_to?(:prune)
    #   elsif options[:only_to_primary] && service.sync_strategies.include?(:to_primary)
    #     @service_logs << service.sync_to_primary(@primary_service)
    #   elsif options[:only_from_primary] && service.sync_strategies.include?(:from_primary)
    #     @service_logs << service.sync_from_primary(@primary_service)
    #   elsif service.sync_strategies.include?(:two_way)
    #     # if the #sync_with_primary method exists, we should use it unless options force us not to
    #     @service_logs << service.sync_with_primary(@primary_service)
    #   else
    #     # Generally we should sync FROM the primary service first, since it should be the source of truth
    #     # and we want to avoid overwriting anything in the primary service if a duplicate task exists
    #     @service_logs << service.sync_from_primary(@primary_service) if service.sync_strategies.include?(:from_primary)
    #     @service_logs << service.sync_to_primary(@primary_service) if service.sync_strategies.include?(:to_primary)
    #   end
    #   options[:logger].save_service_log!(@service_logs)
    # end
    end_time = Time.now
    return if options[:quiet]

    puts "Finished sync at #{end_time.strftime("%Y-%m-%d %I:%M%p")}"
    puts "Sync took #{end_time - start_time} seconds"
  end
end
