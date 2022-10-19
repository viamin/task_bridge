# frozen_string_literal: true

require_relative "task"

module Asana
  # A service class to talk to the Asana API
  class Service
    prepend MemoWise
    
    attr_reader :options, :project_gid

    def initialize(options)
      @options = options
      @personal_access_token = ENV.fetch("ASANA_PERSONAL_ACCESS_TOKEN", nil)
    end

    # TODO: This should support 2-way sync
    # As currently written, this syncs TO Asana only
    def sync(primary_service)
      tasks = primary_service.tasks_to_sync(tags: ["Asana"])
      existing_tasks = tasks_to_sync
      unless options[:quiet]
        progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: tasks.length,
                                         title: "Asana Tasks")
      end
      tasks.each do |task|
        output = if (existing_task = existing_tasks.find { |t| task_title_matches(t, task) })
          update_task(existing_task, task)
        else
          add_task(task) unless task.completed
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{tasks.length} #{options[:primary]} items to Asana" unless options[:quiet]
    end

    # Asana doesn't use tags or an inbox, so just get all tasks in the requested project
    def tasks_to_sync(*)
      projects = list_projects
      matching_project = projects.find { |p| options[:project] == p["name"] }
      @project_gid = matching_project["gid"]
      task_list = list_project_tasks(@project_gid)
      task_list.map { |task| Task.new(task, options) }
    end

    # No-op for now
    def purge
      false
    end

    def add_task(task)
      puts "Called #{self.class}##{__method__}" if options[:debug]
      request_body = { body: { data: task.to_asana(project_gid) }.to_json }
      if options[:pretend]
        "Would have added #{task.title} to Asana"
      else
        response = HTTParty.post("#{base_url}/tasks", authenticated_options.merge(request_body))
        if response.success?
          JSON.parse(response.body)
        else
          puts "Failed to create an Asana task - check personal access token"
          nil
        end
      end
    end

    def update_task(existing_task, task)
      puts "Called #{self.class}##{__method__}" if options[:debug]
      request_body = { body: { data: task.to_asana }.to_json }
      if options[:pretend]
        "Would have updated task #{task.title} in Asana"
      else
        response = HTTParty.put("#{base_url}/tasks/#{existing_task.id}", authenticated_options.merge(request_body))
        if response.success?
          JSON.parse(response.body)
        else
          puts "Failed to update Asana task ##{existing_task.id} with code #{response.code} - check personal access token"
          puts response.body if options[:verbose]
          nil
        end
      end
    end

    private

    def task_title_matches(task, other_task)
      task.title.downcase.strip == other_task.title.downcase.strip
    end

    def list_projects
      response = HTTParty.get("#{base_url}/projects", authenticated_options)
      raise "Error loading Asana tasks - check personal access token" unless response.code == 200

      JSON.parse(response.body)["data"]
    end
    memo_wise :list_projects

    def list_project_tasks(project_gid)
      query = {
        query: {
          project: project_gid,
          opt_fields: Task.requested_fields.join(",")
        }
      }
      response = HTTParty.get("#{base_url}/tasks", authenticated_options.merge(query))
      raise "Error loading Asana tasks - check personal access token" unless response.code == 200

      JSON.parse(response.body)["data"]
    end
    memo_wise :list_project_tasks

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
