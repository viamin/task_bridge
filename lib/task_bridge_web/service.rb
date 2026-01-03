# frozen_string_literal: true

require_relative "task"
require_relative "../base/service"

module TaskBridgeWeb
  class Service < Base::Service
    def initialize(options:)
      super
      @api_key = Chamber.dig!(:task_bridge_web, :api_key)
    end

    def item_class
      Task
    end

    def friendly_name
      "TaskBridgeWeb"
    end

    def sync_strategies
      %i[two_way from_primary]
    end

    def items_to_sync(*)
      tasks = fetch_tasks
      tasks.map { |task| Task.new(task_bridge_web_task: task, options:) }
    end
    memo_wise :items_to_sync

    def add_item(external_task)
      debug("external_task: #{external_task}", options[:debug])
      task_data = Task.from_external(external_task)

      # Handle project creation if task has a project
      if task_data[:project] && !task_data[:project].empty?
        project_id = ensure_project_exists(task_data[:project], external_task.provider)
        task_data[:project_id] = project_id
        task_data.delete(:project)
      end

      request_body = {
        body: { task: task_data }.to_json
      }

      if options[:pretend]
        "Would have added #{external_task.title} to TaskBridge Web"
      else
        debug("request_body: #{request_body.pretty_inspect}", options[:debug])
        response = HTTParty.post("#{base_url}/api/tasks", authenticated_options.merge(request_body))
        if response.success?
          response_body = JSON.parse(response.body)
          new_task = Task.new(task_bridge_web_task: response_body, options:)
          update_sync_data(external_task, new_task.id, new_task.url)
          "Added #{external_task.title} to TaskBridge Web"
        else
          debug(response.body, options[:debug])
          "Failed to create TaskBridge Web task - code #{response.code}"
        end
      end
    end

    def patch_item(task_bridge_web_task, updated_attributes)
      debug("task_bridge_web_task: #{task_bridge_web_task.title}", options[:debug])
      request_body = {
        body: { task: updated_attributes }.to_json
      }

      return "Would have patched task #{task_bridge_web_task.title} with #{updated_attributes.to_json}" if options[:pretend]

      response = HTTParty.put("#{base_url}/api/tasks/#{task_bridge_web_task.id}", authenticated_options.merge(request_body))
      return if response.success?

      debug(response.body, options[:debug])
      "Failed to update TaskBridge Web task ##{task_bridge_web_task.id} with code #{response.code}"
    end

    def update_item(task_bridge_web_task, external_task)
      debug("task_bridge_web_task: #{task_bridge_web_task.title}", options[:debug])
      task_data = Task.from_external(external_task)

      # Handle project creation if task has a project
      if task_data[:project] && !task_data[:project].empty?
        project_id = ensure_project_exists(task_data[:project], external_task.provider)
        task_data[:project_id] = project_id
        task_data.delete(:project)
      end

      request_body = {
        body: { task: task_data }.to_json
      }

      return "Would have updated task #{external_task.title} in TaskBridge Web" if options[:pretend]

      response = HTTParty.put("#{base_url}/api/tasks/#{task_bridge_web_task.id}", authenticated_options.merge(request_body))
      if response.success?
        update_sync_data(external_task, task_bridge_web_task.id, task_bridge_web_task.url) if options[:update_ids_for_existing]
        "Updated #{external_task.title} in TaskBridge Web"
      else
        debug(response.body, options[:debug])
        "Failed to update TaskBridge Web task ##{task_bridge_web_task.id} with code #{response.code}"
      end
    end

    def prune
      completed_tasks = fetch_tasks.select { |task| task["completed"] }
      completed_tasks.each do |task|
        HTTParty.delete("#{base_url}/api/tasks/#{task['id']}", authenticated_options)
      end
      puts "Deleted #{completed_tasks.length} completed tasks from TaskBridge Web" if options[:verbose]
    end

    private

    def min_sync_interval
      30.minutes.to_i
    end

    def fetch_tasks
      response = HTTParty.get("#{base_url}/api/tasks", authenticated_options)
      raise "Error loading TaskBridge Web tasks - check API key and base URL" unless response.success?

      JSON.parse(response.body)
    end
    memo_wise :fetch_tasks

    def fetch_projects
      response = HTTParty.get("#{base_url}/api/projects", authenticated_options)
      return [] unless response.success?

      JSON.parse(response.body)
    end
    memo_wise :fetch_projects

    def ensure_project_exists(project_name, service_type = nil)
      # Look for existing project by name
      existing_project = fetch_projects.find { |project| project["name"] == project_name }
      return existing_project["id"] if existing_project

      # Create new project if it doesn't exist
      create_project(project_name, service_type)
    end

    def create_project(project_name, service_type = nil)
      debug("Creating project: #{project_name}", options[:debug])

      return nil if options[:pretend]

      project_data = { name: project_name }
      project_data[:service_type] = service_type if service_type

      request_body = {
        body: { project: project_data }.to_json
      }

      response = HTTParty.post("#{base_url}/api/projects", authenticated_options.merge(request_body))
      if response.success?
        response_body = JSON.parse(response.body)
        puts "Created project: #{project_name}" if options[:verbose]
        response_body["id"]
      else
        debug("Failed to create project #{project_name}: #{response.body}", options[:debug])
        puts "Failed to create project #{project_name}" if options[:verbose]
        nil
      end
    end

    def authenticated_options
      {
        headers: {
          "Content-Type": "application/json",
          accept: "application/json",
          Authorization: "Bearer #{@api_key}"
        }
      }
    end

    def base_url
      Chamber.dig!(:task_bridge_web, :base_url)
    end
  end
end
