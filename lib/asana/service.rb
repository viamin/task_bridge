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
    end

    # Sync tasks from the primary service to Asana
    def sync_from(primary_service)
      primary_tasks = primary_service.tasks_to_sync(tags: ["Asana"], folder: options[:project])
      asana_tasks = tasks_to_sync
      unless options[:quiet]
        progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: primary_tasks.length,
                                         title: "#{primary_service.class.name} to Asana Tasks")
      end
      primary_tasks.each do |primary_task|
        output = if (existing_task = asana_tasks.find { |asana_task| task_title_matches(asana_task, primary_task) })
          update_task(existing_task, primary_task)
        else
          add_task(primary_task) unless primary_task.completed
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{primary_tasks.length} #{options[:primary]} items to Asana" unless options[:quiet]
    end

    # sync tasks from Asana to the primary service
    def sync_to(primary_service)
      asana_tasks = tasks_to_sync
      primary_tasks = primary_service.tasks_to_sync(tags: ["Asana"])
      unless options[:quiet]
        progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: asana_tasks.length,
                                         title: "#{primary_service.class.name} from Asana Tasks")
      end
      asana_tasks.each do |asana_task|
        output = if (existing_task = primary_tasks.find { |primary_task| task_title_matches(primary_task, asana_task) })
          primary_service.update_task(existing_task, asana_task)
        else
          primary_service.add_task(asana_task) unless asana_task.completed
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{asana_tasks.length} #{options[:primary]} items from Asana" unless options[:quiet]
    end

    # Asana doesn't use tags or an inbox, so just get all tasks in the requested project
    def tasks_to_sync(*)
      task_list = list_project_tasks(project_gid)
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

    # No-op for now
    def purge
      false
    end

    def add_task(external_task, parent_task_gid = nil)
      debug("") if options[:debug]
      request_body = {
        query: { opt_fields: Task.requested_fields.join(",") },
        body: { data: external_task.to_asana.merge(memberships_for_task(external_task)) }.to_json
      }
      if options[:pretend]
        "Would have added #{external_task.title} to Asana"
      else
        endpoint = parent_task_gid.nil? ? "tasks" : "tasks/#{parent_task_gid}/subtasks"
        response = HTTParty.post("#{base_url}/#{endpoint}", authenticated_options.merge(request_body))
        if response.success?
          response_body = JSON.parse(response.body)
          new_task = Task.new(response_body["data"], options)
          handle_subtasks(new_task, external_task)
        else
          puts "Failed to create an Asana task - check personal access token"
          nil
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
            unless project_response.success?
              puts "Failed to update Asana task ##{asana_task.id} with code #{project_response.code}"
              puts project_response.body if options[:debug]
              nil
            end
          end
          # response_body = JSON.parse(response.body)
          # updated_task = Task.new(response_body["data"], options)
          handle_subtasks(asana_task, external_task)
        else
          puts "Failed to update Asana task ##{asana_task.id} with code #{response.code}"
          puts response.body if options[:verbose]
          nil
        end
      end
    end

    private

    # create or update subtasks on a task
    def handle_subtasks(asana_task, external_task)
      debug("") if options[:debug]
      return unless external_task.respond_to?(:subtask_count) && external_task.subtask_count.positive?

      external_task.subtasks.each do |subtask|
        if (existing_task = asana_task.subtasks.find { |asana_subtask| task_title_matches(asana_subtask, subtask) })
          update_task(existing_task, subtask)
          "Updated subtask #{subtask.title} of task #{external_task.title} in Omnifocus"
        else
          add_task(subtask, asana_task.id) unless subtask.completed?
          "Created subtask #{subtask.title} of task #{external_task.title} in Omnifocus"
        end
      end
    end

    def task_title_matches(task, other_task)
      task.title.downcase.strip == other_task.title.downcase.strip
    end

    def project_gid
      all_projects = list_projects
      matching_project = all_projects.find { |project| options[:project] == project["name"] }
      matching_project["gid"]
    end
    memo_wise :project_gid

    def list_projects
      response = HTTParty.get("#{base_url}/projects", authenticated_options)
      raise "Error loading Asana tasks - check personal access token" unless response.success?

      JSON.parse(response.body)["data"]
    end
    memo_wise :list_projects

    def list_project_sections
      query = {
        query: {
          project: project_gid
        }
      }
      response = HTTParty.get("#{base_url}/projects/#{project_gid}/sections", authenticated_options.merge(query))
      raise "Error loading Asana project sections - check personal access token" unless response.success?

      JSON.parse(response.body)["data"]
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

    # Makes some big assumptions about the layout in Asana...
    def memberships_for_task(external_task)
      matching_section = list_project_sections.find { |section| section["name"] == external_task.project }
      if matching_section
        {
          project: project_gid,
          section: matching_section["gid"]
        }
      else
        { project: project_gid }
      end
    end
    memo_wise :memberships_for_task

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
