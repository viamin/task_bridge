# frozen_string_literal: true

module Asana
  # A service class to talk to the Asana API
  class Service < Base::Service
    attr_reader :authorized

    def initialize(options: nil)
      super
      @personal_access_token = asana_settings.fetch("personal_access_token") do
        asana_settings.fetch(:personal_access_token)
      end
      @authorized = true
    rescue StandardError => e
      # If configuration is missing, skip the service
      puts "Asana initialization failed: #{e.message}" unless self.options[:quiet]
      @authorized = false
    end

    def item_class
      Task
    end

    def friendly_name
      "Asana"
    end

    def sync_strategies
      [:two_way]
    end

    # Asana doesn't use tags or an inbox, so just get all tasks in the requested project
    def items_to_sync(*, only_modified_dates: false, **)
      visible_project_gids = list_projects.map { |project| project["gid"] }
      task_list = visible_project_gids.each_with_object({}) do |project_gid, tasks_by_gid|
        list_project_tasks(project_gid, only_modified_dates:).each do |external_task|
          task_gid = external_task[Task.external_attribute_map[:external_id]]
          tasks_by_gid[task_gid] ||= [external_task, project_gid]
        end
      end.values

      tasks = task_list.map do |external_task|
        task_hash, synced_project_gid = external_task
        asana_task = Task.find_or_initialize_by(external_id: task_hash[Task.external_attribute_map[:external_id]])
        asana_task.options = self.class.build_options(asana_task.options, service_name)
        asana_task.synced_project_gid = synced_project_gid
        asana_task.asana_task = task_hash
        asana_task.refresh_from_external!(only_modified_dates:)
      end
      sub_item_ids = Set.new
      tasks_with_sub_items = tasks.select { |task| task.sub_item_count&.positive? }
      if tasks_with_sub_items.any?
        tasks_with_sub_items.each do |parent_task|
          sub_item_hashes = list_task_sub_items(parent_task.external_id, only_modified_dates:)
          sub_item_hashes.each do |sub_item_hash|
            sub_item = Task.find_or_initialize_by(external_id: sub_item_hash[Task.external_attribute_map[:external_id]])
            sub_item.options = self.class.build_options(sub_item.options, service_name)
            sub_item.asana_task = sub_item_hash
            sub_item.refresh_from_external!(only_modified_dates:)
            parent_task.sub_items << sub_item
            sub_item_ids << sub_item.external_id
          end
        end
      end
      tasks.reject { |task| sub_item_ids.include?(task.external_id) }
    end

    def add_item(external_task, parent_task_gid = nil)
      debug("external_task: #{external_task}, parent_task_gid: #{parent_task_gid}", options[:debug])
      request_body = {
        query: { opt_fields: Task.requested_fields.join(",") },
        body: { data: Task.from_external(external_task).merge(memberships_for_task(external_task, for_create: true)) }.to_json
      }
      return "Would have added #{external_task.title} to Asana" if options[:pretend]

      endpoint = parent_task_gid.nil? ? "tasks" : "tasks/#{parent_task_gid}/subtasks"
      debug("request_body: #{request_body.pretty_inspect} sending to #{endpoint}", options[:debug])
      response = HTTParty.post("#{base_url}/#{endpoint}", authenticated_options.merge(request_body))
      return failure_message("create an Asana task", response) unless response.success?

      response_body = JSON.parse(response.body)
      new_task = Task.new(
        asana_task: response_body["data"],
        options: self.class.build_options(options, service_name)
      ).tap(&:refresh_from_external!)
      section_move_error = move_task_to_section(section_identifier_for(external_task), new_task.external_id)
      handle_sub_items(new_task, external_task)
      update_sync_data(external_task, new_task.external_id, new_task.url)
      return section_move_error if section_move_error.present?

      new_task
    end

    # Asana's update task API supports a PATCH-like syntax using PUT
    def patch_item(asana_task, updated_attributes)
      debug("asana_task: #{asana_task.title}", options[:debug])
      request_body = {
        query: { opt_fields: Task.requested_fields.join(",") },
        body: updated_attributes.to_json
      }
      return "Would have patched task #{asana_task.title} with #{updated_attributes.to_json}" if options[:pretend]

      response = HTTParty.put("#{base_url}/tasks/#{asana_task.external_id}", authenticated_options.merge(request_body))
      return if response.success?

      debug(response.body, options[:debug])
      "Failed to update Asana task ##{asana_task.external_id} with code #{response.code}"
    end

    def update_item(asana_task, external_task)
      debug("asana_task: #{asana_task.title}", options[:debug])
      request_body = {
        query: { opt_fields: Task.requested_fields.join(",") },
        body: { data: Task.from_external(external_task) }.to_json
      }
      return "Would have updated task #{external_task.title} in Asana" if options[:pretend]

      response = HTTParty.put("#{base_url}/tasks/#{asana_task.external_id}", authenticated_options.merge(request_body))
      return failure_message("update Asana task ##{asana_task.external_id}", response) unless response.success?

      # Detect if this was a title match vs ID match
      # Title match: external_task doesn't have our sync ID
      matched_by_title = matched_by_title?(external_task, asana_task)
      project_changed = project_name_for(asana_task.project) != project_name_for(external_task.project)

      # Only move projects/sections for ID-matched items (reliable link)
      # Title matches are not reliable enough to warrant moving tasks between projects
      section_move_error = nil
      if !matched_by_title && external_task.project && project_changed
        request_body = { body: JSON.dump({ data: memberships_for_task(external_task) }) }
        project_response = HTTParty.post("#{base_url}/tasks/#{asana_task.external_id}/addProject", authenticated_options.merge(request_body))
        return failure_message("update Asana task ##{asana_task.external_id}", project_response) unless project_response.success?

        section_gid = section_or_default_identifier_for(external_task)
        section_move_error = move_task_to_section(section_gid, asana_task.external_id) if section_gid.present?
      elsif !matched_by_title && section_change_requested?(asana_task, external_task)
        section_gid = section_or_default_identifier_for(external_task)
        section_move_error = move_task_to_section(section_gid, asana_task.external_id) if section_gid.present? && current_section_gid_for(asana_task) != section_gid
      end
      handle_sub_items(asana_task, external_task)
      # Add sync ID so future syncs use ID matching instead of title matching
      update_sync_data(external_task, asana_task.external_id, asana_task.url) if matched_by_title || options[:update_ids_for_existing]
      section_move_error
    end

    # Defines the conditions under which a task should be not be created,
    # either in the primary_service or in Asana
    def skip_create?(task)
      return true if task.completed?

      raise "task #{task.friendly_title} doesn't respond to :assignee" unless task.respond_to?(:assignee)

      # create the task (don't skip) if it's unassigned
      return false if task.assignee.nil?

      # Skip creation if the Asana task is assigned to someone
      # other than the API user
      task.assignee != asana_user["gid"]
    end

    private

    # the minimum time we should wait between syncing tasks
    def min_sync_interval
      30.minutes.to_i
    end

    # create or update sub_items on a task
    def handle_sub_items(asana_task, external_task)
      debug("", options[:debug])
      return unless external_task.respond_to?(:sub_item_count) && external_task.sub_item_count.positive?

      external_task.sub_items.each do |sub_item|
        if (existing_task = sub_item.find_matching_item_in(asana_task.sub_items))
          update_item(existing_task, sub_item)
          "Updated sub_item #{sub_item.title} of task #{external_task.title} in Asana"
        else
          add_item(sub_item, asana_task.external_id) unless sub_item.completed?
          "Created sub_item #{sub_item.title} of task #{external_task.title} in Asana"
        end
      end
    end

    # By default, this will list only active (unarchived) projects. Passing archived: true
    # will return only archived projects.
    def list_projects(archived: false)
      workspace_gids.each_with_object([]) do |workspace_gid, projects|
        projects.concat(list_workspace_projects(workspace_gid, archived:))
      end
    end
    memo_wise :list_projects

    def list_workspace_projects(workspace_gid, archived: false)
      query = { query: { archived: } }
      response = HTTParty.get("#{base_url}/workspaces/#{workspace_gid}/projects", authenticated_options.merge(query))
      raise "Error loading Asana projects - check personal access token" unless response.success?

      JSON.parse(response.body)["data"]
    end

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

    def list_project_tasks(project_gid, only_modified_dates: false)
      query = {
        query: {
          opt_fields: Task.requested_fields(only_modified_dates:).join(","),
          # Return incomplete tasks + tasks completed within the last week
          # This gives leeway for sync delays while reducing API response size
          completed_since: completed_since_timestamp
        }
      }
      # Only use incremental reads when the caller explicitly asked for the
      # lightweight date-only path. Full reads need the complete comparison set.
      query[:query][:modified_since] = last_sync_time.iso8601 if only_modified_dates && last_sync_time.present?

      response = HTTParty.get("#{base_url}/projects/#{project_gid}/tasks", authenticated_options.merge(query))
      raise "Error loading Asana tasks - check personal access token" unless response.success?

      JSON.parse(response.body)["data"]
    end

    def list_task_sub_items(task_gid, only_modified_dates: false)
      query = {
        query: {
          opt_fields: Task.requested_fields(only_modified_dates:).join(","),
          # Return incomplete subtasks + subtasks completed within the last week
          completed_since: completed_since_timestamp
        }
      }
      # Keep full comparison scans complete; only incremental date reads should
      # constrain the remote fetch cursor.
      query[:query][:modified_since] = last_sync_time.iso8601 if only_modified_dates && last_sync_time.present?

      response = HTTParty.get("#{base_url}/tasks/#{task_gid}/subtasks", authenticated_options.merge(query))
      raise "Error loading Asana task subtasks - check personal access token" unless response.success?

      JSON.parse(response.body)["data"]
    end

    def move_task_to_section(section_gid, task_gid)
      return if section_gid.blank?

      request_body = { body: { data: { task: task_gid } }.to_json }
      response = HTTParty.post("#{base_url}/sections/#{section_gid}/addTask", authenticated_options.merge(request_body))
      return if response.success?

      failure_message("move an Asana task to a section", response)
    end

    def section_identifier_for(external_task)
      project_gid = project_gid_from_name(project_name_for(external_task.project))
      matching_section_gid_for(external_task, project_gid)
    end

    def section_or_default_identifier_for(external_task)
      project_gid = project_gid_from_name(project_name_for(external_task.project))
      return if project_gid.blank?

      matching_section_gid_for(external_task, project_gid) || default_section_gid_for(project_gid)
    end

    def matched_by_title?(external_task, asana_task)
      current_sync_id = external_task.try(:"#{service_identifier_for(service_name)}_id")
      current_sync_id.blank? || current_sync_id != asana_task.external_id
    end

    def memberships_for_task(external_task, for_create: false)
      project_string = external_task.project
      return {} if project_string.blank?

      # Find the project GID by name
      project_gid = project_gid_from_name(project_name_for(project_string))
      if project_gid.blank?
        project_name = project_name_for(project_string)
        unless @_unmatched_projects&.include?(project_name)
          (@_unmatched_projects ||= Set.new) << project_name
          warn "[Asana] No matching Asana project for #{project_name.inspect}"
        end
        return {}
      end

      if for_create
        { projects: [project_gid] }
      else
        { project: project_gid, section: matching_section_gid_for(external_task, project_gid) }.compact
      end
    end

    def matching_section_gid_for(external_task, project_gid)
      matching_section_hash_for(external_task, project_gid)&.dig("gid")
    end

    def section_hashes_for(project_gid)
      @section_hashes_by_project_gid ||= {}
      @section_hashes_by_project_gid[project_gid] ||= list_project_sections(project_gid, merge_project_gids: true)
    end

    def default_section_gid_for(project_gid)
      section_hashes_for(project_gid).find { |section| section["name"] == "Untitled section" }&.dig("gid")
    end

    def current_section_gid_for(asana_task)
      membership_for(asana_task)&.dig("section", "gid")
    end

    def section_change_requested?(asana_task, external_task)
      return false if external_task.project.blank?

      return false unless external_task.respond_to?(:tags)

      section_tags = Array(external_task.tags)
      return asana_task.section.present? if section_tags.empty?

      project_gid = project_gid_from_name(project_name_for(external_task.project))
      matching_section = matching_section_hash_for(external_task, project_gid)
      return false if matching_section.blank?

      matching_section["name"] != asana_task.section
    end

    def membership_for(asana_task)
      memberships = asana_task.asana_task["memberships"]
      return if memberships.blank?

      project_gid =
        asana_task.synced_project_gid.presence ||
        asana_task.asana_task["projects"]&.first&.dig("gid") ||
        project_gid_from_name(project_name_for(asana_task.project))
      memberships.find { |membership| membership.dig("project", "gid") == project_gid } || memberships.first
    end

    def matching_section_hash_for(external_task, project_gid)
      return if project_gid.blank?

      section_hashes_for(project_gid).find do |section|
        Array(external_task.tags).include?(section["name"])
      end
    end

    def project_name_for(project_string)
      project_string.to_s.split(":", 2).first
    end

    def workspace_gids
      response = HTTParty.get("#{base_url}/workspaces", authenticated_options)
      raise "Error loading Asana workspaces - check personal access token" unless response.success?

      JSON.parse(response.body)["data"].map { |workspace| workspace["gid"] }
    end
    memo_wise :workspace_gids

    def asana_user
      response = HTTParty.get("#{base_url}/users/me", authenticated_options)
      raise "Error loading Asana user - check personal access token" unless response.success?

      JSON.parse(response.body)["data"]&.stringify_keys || {}
    end

    def authenticated_options
      {
        headers: {
          "Content-Type": "application/json",
          accept: "application/json",
          Authorization: "Bearer #{@personal_access_token}"
        }
      }
    end

    def failure_message(action, response)
      debug(response.body, options[:debug])
      message = "Failed to #{action} - code #{response.code}"
      error_detail = response_error_detail(response)
      message += " (#{error_detail})" if error_detail
      message
    end

    def response_error_detail(response)
      parsed_body = JSON.parse(response.body)
      parsed_body.dig("errors", 0, "message") || parsed_body["error"]
    rescue JSON::ParserError, TypeError
      nil
    end

    def base_url
      "https://app.asana.com/api/1.0"
    end

    def asana_settings
      return Chamber.dig!(:asana) if instance_name.blank?

      Chamber.dig(:asana, instance_name) || Chamber.dig(:asana, instance_name.to_sym) ||
        raise("Missing Asana config for instance #{instance_name}")
    end

    # Returns timestamp for 1 week ago, used to filter completed tasks
    # This allows syncing recently completed tasks while reducing API response size
    def completed_since_timestamp
      Chronic.parse("1 week ago").iso8601
    end
    memo_wise :completed_since_timestamp

    # Returns the last successful sync time from the logger, or nil if never synced
    def last_sync_time
      last_successful_sync_at
    end
    memo_wise :last_sync_time
  end
end
