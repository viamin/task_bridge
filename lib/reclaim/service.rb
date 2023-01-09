# frozen_string_literal: true

require_relative "task"

module Reclaim
  # Reclaim sync is currently unsupported since the API is not public and
  # this is not expected to work
  class Service
    attr_reader :options

    def initialize(options)
      @options = options
      @auth_cookie = ENV.fetch("RECLAIM_AUTH_TOKEN", nil)
    rescue StandardError
      # If authentication fails, skip the service
      nil
    end

    def friendly_name
      "Reclaim"
    end

    def sync_from_primary(primary_service)
      tasks = primary_service.tasks_to_sync(tags: [friendly_name])
      existing_tasks = tasks_to_sync
      unless options[:quiet]
        progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: tasks.length,
                                         title: "Reclaim Tasks")
      end
      tasks.each do |task|
        output = if (existing_task = existing_tasks.find { |t| friendly_titles_match?(t, task) })
          update_task(existing_task, task)
        else
          add_task(task) unless task.completed
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{tasks.length} #{options[:primary]} items to Reclaim Tasks" unless options[:quiet]
      { service: friendly_name, last_attempted: options[:sync_started_at], last_successful: options[:sync_started_at], items_synced: tasks.length }.stringify_keys
    end

    # Reclaim doesn't use tags or an inbox, so just get all tasks that the user has access to
    def tasks_to_sync(*)
      list_tasks.map { |reclaim_task| Task.new(reclaim_task, options) }
    end

    def add_task(task)
      puts "Called #{self.class}##{__method__}" if options[:debug]
      request_body = { body: task.to_json }
      if options[:pretend]
        "Would have added #{task.title} to Reclaim"
      else
        response = HTTParty.post("#{base_url}/tasks", authenticated_options.merge(request_body))
        if response.success?
          JSON.parse(response.body)
        else
          puts "Failed to create a Reclaim task - check auth cookie"
          nil
        end
      end
    end

    def update_task(existing_task, task)
      puts "Called #{self.class}##{__method__}" if options[:debug]
      request_body = { body: task.to_json }
      if options[:pretend]
        "Would have updated task #{task.title} in Reclaim"
      else
        response = HTTParty.put("#{base_url}/tasks/#{existing_task.id}", authenticated_options.merge(request_body))
        if response.success?
          JSON.parse(response.body)
        else
          puts "Failed to update Reclaim task ##{existing_task.id} with code #{response.code} - check auth cookie"
          puts response.body if options[:verbose]
          nil
        end
      end
    end

    private

    def delete_task(task)
      HTTParty.delete("#{base_url}/planner/policy/task/#{task.id}", authenticated_options)
    end

    def friendly_titles_match?(task, other_task)
      task.title.downcase.strip == other_task.title.downcase.strip
    end

    def list_tasks
      query = {
        query: {
          status: "COMPLETE,NEW,SCHEDULED,IN_PROGRESS",
          instances: true
        }
      }
      response = HTTParty.get("#{base_url}/tasks", authenticated_options.merge(query))
      raise "Error loading Reclaim tasks - check cookie expiration" unless response.success?

      JSON.parse(response.body)
    end

    def authenticated_options
      {
        headers: {
          :accept => "application/json",
          "Cookie" => "RECLAIM=#{@auth_cookie}"
        }
      }
    end

    def base_url
      "https://api.app.reclaim.ai/api"
    end
  end
end
