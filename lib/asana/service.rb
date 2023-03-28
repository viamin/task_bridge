# frozen_string_literal: true

require_relative "task"
require_relative "../base/service"

module Asana
  # A service class to talk to the Asana API
  class Service < Base::Service
    def initialize(options:)
      super
      @personal_access_token = ENV.fetch("ASANA_PERSONAL_ACCESS_TOKEN", nil)
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
    def items_to_sync(*)
      visible_project_gids = list_projects.map { |project| project["gid"] }
      task_list = visible_project_gids.map { |project_gid| list_project_tasks(project_gid) }.flatten.uniq
      tasks = task_list.map { |task| Task.new(asana_task: task, options:) }
      tasks_with_sub_items = tasks.select { |task| task.sub_item_count.positive? }
      if tasks_with_sub_items.any?
        tasks_with_sub_items.each do |parent_task|
          sub_item_hashes = list_task_sub_items(parent_task.id)
          sub_item_hashes.each do |sub_item_hash|
            sub_item = Task.new(asana_task: sub_item_hash, options:)
            parent_task.sub_items << sub_item
            # Remove the sub_item from the main task list
            # so we don't double sync them
            # (the Asana API doesn't have a filter for sub_items)
            tasks.delete_if { |task| task.id == sub_item.id }
          end
        end
      end
      tasks
    end
    memo_wise :items_to_sync

    def add_item(external_task, parent_task_gid = nil)
      debug("external_task: #{external_task}, parent_task_gid: #{parent_task_gid}", options[:debug])
      request_body = {
        query: { opt_fields: Task.requested_fields.join(",") },
        body: { data: external_task.to_asana.merge(memberships_for_task(external_task, for_create: true)) }.to_json
      }
      if options[:pretend]
        "Would have added #{external_task.title} to Asana"
      else
        endpoint = parent_task_gid.nil? ? "tasks" : "tasks/#{parent_task_gid}/subtasks"
        debug("request_body: #{request_body.pretty_inspect} sending to #{endpoint}", options[:debug])
        response = HTTParty.post("#{base_url}/#{endpoint}", authenticated_options.merge(request_body))
        if response.success?
          response_body = JSON.parse(response.body)
          new_task = Task.new(asana_task: response_body["data"], options:)
          if (section = memberships_for_task(external_task)["section"])
            request_body = { body: { data: { task: new_task.id } }.to_json }
            response = HTTParty.post("#{base_url}/sections/#{section}/addTask", authenticated_options.merge(request_body))
            unless response.success?
              debug(response.body, options[:debug])
              "Failed to move an Asana task to a section - code #{response.code}"
            end
          end
          handle_sub_items(new_task, external_task)
          update_sync_data(external_task, new_task.id, new_task.url)
        else
          debug(response.body, options[:debug])
          "Failed to create an Asana task - code #{response.code}"
        end
      end
    end

    # Asana's update task API supports a PATCH-like syntax using PUT
    def patch_item(asana_task, updated_attributes)
      debug("asana_task: #{asana_task.title}", options[:debug])
      request_body = {
        query: { opt_fields: Task.requested_fields.join(",") },
        body: updated_attributes.to_json
      }
      return "Would have patched task #{asana.title} with #{updated_attributes.to_json}" if options[:pretend]

      response = HTTParty.put("#{base_url}/tasks/#{asana_task.id}", authenticated_options.merge(request_body))
      return if response.success?

      debug(response.body, options[:debug])
      "Failed to update Asana task ##{asana_task.id} with code #{response.code}"
    end

    def update_item(asana_task, external_task)
      debug("asana_task: #{asana_task.title}", options[:debug])
      request_body = {
        query: { opt_fields: Task.requested_fields.join(",") },
        body: { data: external_task.to_asana }.to_json
      }
      return "Would have updated task #{external_task.title} in Asana" if options[:pretend]

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
                debug(response.body, options[:debug])
                "Failed to move an Asana task to a section - code #{response.code}"
              end
            end
          else
            debug(project_response.body, options[:debug])
            "Failed to update Asana task ##{asana_task.id} with code #{project_response.code}"
          end
        end
        handle_sub_items(asana_task, external_task)
        update_sync_data(external_task, asana_task.id, asana_task.url) if options[:update_ids_for_existing]
      else
        debug(response.body, options[:debug])
        "Failed to update Asana task ##{asana_task.id} with code #{response.code}"
      end
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
      5.minutes.to_i
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
          add_item(sub_item, asana_task.id) unless sub_item.completed?
          "Created sub_item #{sub_item.title} of task #{external_task.title} in Asana"
        end
      end
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

    def list_task_sub_items(task_gid)
      query = {
        query: {
          opt_fields: Task.requested_fields.join(",")
        }
      }
      response = HTTParty.get("#{base_url}/tasks/#{task_gid}/subtasks", authenticated_options.merge(query))
      raise "Error loading Asana task subtasks - check personal access token" unless response.success?

      JSON.parse(response.body)["data"]
    end
    memo_wise :list_task_sub_items

    # Makes some big assumptions about the layout we use in Asana...
    # Namely that all Asana projects passed into TaskBridge
    # will only have sections or top level tasks and sub_items,
    # but only one level deep (meaning sub_items will not have
    # sub_items of their own and sections will not have subsections)
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

      JSON.parse(response.body)["data"]&.stringify_keys
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
