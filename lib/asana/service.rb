# frozen_string_literal: true

require_relative "task"

module Asana
  # A service class to talk to the Asana API
  class Service
    prepend MemoWise
    include Debug

    attr_reader :options

    def initialize(options)
      @options = options
      @personal_access_token = ENV.fetch("ASANA_PERSONAL_ACCESS_TOKEN", nil)
      @last_sync_data = options[:logger].sync_data_for(tag_name)
    end

    def tag_name
      "Asana"
    end

    # For new tasks on either service, creates new matching ones
    # for existing tasks, first check for an updated_at timestamp
    # and sync from the service with the newer modification
    def sync_with_primary(primary_service)
      return @last_sync_data unless should_sync?

      primary_tasks = primary_service.tasks_to_sync(tags: [tag_name])
      asana_tasks = tasks_to_sync
      # Step 1: pair tasks that have matching sync_ids
      paired_tasks = {}
      primary_tasks.each do |primary_task|
        matching_task = asana_tasks.find { |asana_task| (asana_task.sync_id == primary_task.id) || (asana_task.id == primary_task.sync_id) }
        paired_tasks[primary_task] = matching_task if matching_task
      end
      unmatched_primary_tasks = primary_tasks - paired_tasks.keys
      unmatched_asana_tasks = asana_tasks - paired_tasks.values
      tasks_grouped_by_title = (unmatched_primary_tasks + unmatched_asana_tasks).group_by { |task| task.title.downcase.strip }
      unless options[:quiet]
        progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ",
                                         total: paired_tasks.length + tasks_grouped_by_title.length,
                                         title: "#{primary_service.class.name} syncing with Asana")
      end
      paired_tasks.each do |primary_task, asana_task|
        if primary_task.updated_at > asana_task.updated_at
          update_task(asana_task, primary_task)
        else
          primary_service.update_task(primary_task, asana_task)
        end
      end
      tasks_grouped_by_title.each do |_title, tasks|
        output = case tasks.length
                 when 1
                   task = tasks.first
                   if task.instance_of?(Asana::Task)
                     unless task.assignee == asana_user["gid"] || task.assignee.nil?
                       # Skip creating new tasks that are not assigned to the owner of the Personal Access Token
                       # Unassigned tasks are fine to create as well
                       progressbar.increment unless options[:quiet]
                       next
                     end
                     primary_service.add_task(task) unless task.completed?
                   else # task is a primary_service task
                     add_task(task) unless task.completed?
                   end
                 when 2 # task already exists
                   newer_task = tasks.max_by(&:updated_at)
                   older_task = tasks.min_by(&:updated_at)
                   if should_sync?(newer_task.updated_at)
                     if newer_task.instance_of?(Asana::Task) && !older_task.instance_of?(Asana::Task)
                       primary_service.update_task(older_task, newer_task)
                     elsif newer_task.instance_of?(Asana::Task) && older_task.instance_of?(Asana::Task)
                       primary_service.add_task(older_task) unless older_task.completed?
                       primary_service.add_task(newer_task) unless newer_task.completed?
                     elsif !newer_task.instance_of?(Asana::Task) && !older_task.instance_of?(Asana::Task)
                       add_task(older_task) unless older_task.completed?
                       add_task(newer_task) unless newer_task.completed?
                     else
                       update_task(older_task, newer_task)
                     end
                   elsif options[:debug]
                     debug("Skipping sync of #{newer_task.title} (should_sync? == false)")
                   end
                 else
                   puts tasks.map(&:title)
          # raise "Too many tasks!"
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{paired_tasks.length + tasks_grouped_by_title.length} #{options[:primary]} and Asana items" unless options[:quiet]
      { service: tag_name, last_attempted: options[:sync_started_at], last_successful: options[:sync_started_at], items_synced: paired_tasks.length + tasks_grouped_by_title.length }.stringify_keys
    end

    # Asana doesn't use tags or an inbox, so just get all tasks in the requested project
    def tasks_to_sync(*)
      visible_project_gids = list_projects.map { |project| project["gid"] }
      task_list = visible_project_gids.map { |project_gid| list_project_tasks(project_gid) }.flatten.uniq
      tasks = task_list.map { |task| Task.new(task, options) }
      tasks_with_subtasks = tasks.select { |task| task.subtask_count.positive? }
      if tasks_with_subtasks.any?
        tasks_with_subtasks.each do |parent_task|
          subtask_hashes = list_task_subtasks(parent_task.id)
          subtask_hashes.each do |subtask_hash|
            subtask = Task.new(subtask_hash, options)
            parent_task.subtasks << subtask
            # Remove the subtask from the main task list
            # so we don't double sync them
            # (the Asana API doesn't have a filter for subtasks)
            tasks.delete_if { |task| task.id == subtask.id }
          end
        end
      end
      tasks
    end
    memo_wise :tasks_to_sync

    def add_task(external_task, parent_task_gid = nil)
      debug("external_task: #{external_task}, parent_task_gid: #{parent_task_gid}") if options[:debug]
      request_body = {
        query: { opt_fields: Task.requested_fields.join(",") },
        body: { data: external_task.to_asana.merge(memberships_for_task(external_task, for_create: true)) }.to_json
      }
      if options[:pretend]
        "Would have added #{external_task.title} to Asana"
      else
        endpoint = parent_task_gid.nil? ? "tasks" : "tasks/#{parent_task_gid}/subtasks"
        debug("request_body: #{request_body.pretty_inspect} sending to #{endpoint}") if options[:debug]
        response = HTTParty.post("#{base_url}/#{endpoint}", authenticated_options.merge(request_body))
        if response.success?
          response_body = JSON.parse(response.body)
          new_task = Task.new(response_body["data"], options)
          if (section = memberships_for_task(external_task)["section"])
            request_body = { body: { data: { task: new_task.id } }.to_json }
            response = HTTParty.post("#{base_url}/sections/#{section}/addTask", authenticated_options.merge(request_body))
            unless response.success?
              debug(response.body) if options[:debug]
              "Failed to move an Asana task to a section - code #{response.code}"
            end
          end
          handle_subtasks(new_task, external_task)
        else
          debug(response.body) if options[:debug]
          "Failed to create an Asana task - code #{response.code}"
        end
      end
    end

    def update_task(asana_task, external_task)
      debug("asana_task: #{asana_task.title}") if options[:debug]
      request_body = {
        query: { opt_fields: Task.requested_fields.join(",") },
        body: { data: external_task.to_asana }.to_json
      }
      if options[:pretend]
        "Would have updated task #{external_task.title} in Asana"
      else
        response = HTTParty.put("#{base_url}/tasks/#{asana_task.id}", authenticated_options.merge(request_body))
        if response.success?
          # check if the project or section need to change
          if external_task.project && (asana_task.project != external_task.project)
            request_body = { body: JSON.dump({ data: memberships_for_task(external_task) }) }
            project_response = HTTParty.post("#{base_url}/tasks/#{asana_task.id}/addProject", authenticated_options.merge(request_body))
            if project_response.success?
              if (section = memberships_for_task(external_task)["section"])
                request_body = { body: { data: { task: asana_task.id } }.to_json }
                response = HTTParty.post("#{base_url}/sections/#{section}/addTask", authenticated_options.merge(request_body))
                unless response.success?
                  debug(response.body) if options[:debug]
                  "Failed to move an Asana task to a section - code #{response.code}"
                end
              end
            else
              debug(project_response.body) if options[:debug]
              "Failed to update Asana task ##{asana_task.id} with code #{project_response.code}"
            end
          end
          handle_subtasks(asana_task, external_task)
        else
          debug(response.body) if options[:debug]
          "Failed to update Asana task ##{asana_task.id} with code #{response.code}"
        end
      end
    end

    def should_sync?(task_updated_at = nil)
      time_since_last_sync = options[:logger].last_synced(tag_name, interval: task_updated_at.nil?)
      if task_updated_at.present?
        time_since_last_sync < task_updated_at
      else
        time_since_last_sync > min_sync_interval
      end
    end

    private

    # the minimum time we should wait between syncing tasks
    def min_sync_interval
      5.minutes.to_i
    end

    # create or update subtasks on a task
    def handle_subtasks(asana_task, external_task)
      debug("") if options[:debug]
      return unless external_task.respond_to?(:subtask_count) && external_task.subtask_count.positive?

      external_task.subtasks.each do |subtask|
        if (existing_task = asana_task.subtasks.find { |asana_subtask| friendly_titles_match?(asana_subtask, subtask) })
          update_task(existing_task, subtask)
          "Updated subtask #{subtask.title} of task #{external_task.title} in Asana"
        else
          add_task(subtask, asana_task.id) unless subtask.completed?
          "Created subtask #{subtask.title} of task #{external_task.title} in Asana"
        end
      end
    end

    def friendly_titles_match?(task, other_task)
      task.title.downcase.strip == other_task.title.downcase.strip
    end

    # By default, this will list only active (unarchived) projects. Passing archived: true
    # will return only archived projects.
    def list_projects(archived: false)
      query = { query: { archived: } }
      response = HTTParty.get("#{base_url}/projects", authenticated_options.merge(query))
      raise "Error loading Asana projects - check personal access token" unless response.success?

      JSON.parse(response.body)["data"]
    end
    memo_wise :list_projects

    def project_gids
      @project_gids ||= list_projects.map { |project| project["gid"] }
    end

    def project_gid_from_name(project_name)
      found_project = list_projects.find { |project| project["name"] == project_name }
      return unless found_project

      found_project["gid"]
    end

    # For a given project_gid, list all of the sections in that project
    # It *looks* like Asana will always return an untitled section,
    # even if there are no other sections e.g.:
    # {
    #   "gid": "1203188830269577",
    #   "name": "Untitled section",
    #   "resource_type": "section"
    # },
    def list_project_sections(project_gid, merge_project_gids: false)
      query = {
        query: {
          project: project_gid
        }
      }
      response = HTTParty.get("#{base_url}/projects/#{project_gid}/sections", authenticated_options.merge(query))
      raise "Error loading Asana project sections - check personal access token" unless response.success?

      body_data = JSON.parse(response.body)["data"]

      return body_data unless merge_project_gids

      body_data.map { |section_hash| section_hash.merge("project_gid" => project_gid) }
    end
    memo_wise :list_project_sections

    def list_project_tasks(project_gid)
      query = {
        query: {
          opt_fields: Task.requested_fields.join(",")
        }
      }
      response = HTTParty.get("#{base_url}/projects/#{project_gid}/tasks", authenticated_options.merge(query))
      raise "Error loading Asana tasks - check personal access token" unless response.success?

      JSON.parse(response.body)["data"]
    end
    memo_wise :list_project_tasks

    def list_task_subtasks(task_gid)
      query = {
        query: {
          opt_fields: Task.requested_fields.join(",")
        }
      }
      response = HTTParty.get("#{base_url}/tasks/#{task_gid}/subtasks", authenticated_options.merge(query))
      raise "Error loading Asana task subtasks - check personal access token" unless response.success?

      JSON.parse(response.body)["data"]
    end
    memo_wise :list_task_subtasks

    # Makes some big assumptions about the layout we use in Asana...
    # Namely that all Asana projects passed into TaskBridge
    # will only have sections or top level tasks and subtasks,
    # but only one level deep (meaning subtasks will not have
    # subtasks of their own and sections will not have subsections)
    # Also projects will not have sub-projects
    # And finally, section names are unique across projects (otherwise
    # tasks might get saved into the wrong projects in Asana)
    def memberships_for_task(external_task, for_create: false)
      matching_section = project_gids
                         .map { |project_gid| list_project_sections(project_gid, merge_project_gids: true) }
                         .flatten
                         .find { |section| section["name"] == external_task.project }
      project_gid = matching_section.present? ? matching_section["project_gid"] : project_gid_from_name(external_task.project)
      if for_create
        { projects: [project_gid] }
      else
        {
          project: project_gid,
          section: matching_section&.send(:[], "gid")
        }.compact
      end
    end
    memo_wise :memberships_for_task

    def workspace_gids
      workspaces = asana_user["workspaces"]
      workspaces.map { |workspace| workspace["gid"] }
    end

    def asana_user
      response = HTTParty.get("#{base_url}/users/me", authenticated_options)
      raise "Error loading Asana user - check personal access token" unless response.success?

      JSON.parse(response.body)["data"]
    end
    memo_wise :asana_user

    def authenticated_options
      {
        headers: {
          "Content-Type": "application/json",
          accept: "application/json",
          Authorization: "Bearer #{@personal_access_token}"
        }
      }
    end

    def base_url
      "https://app.asana.com/api/1.0"
    end
  end
end
