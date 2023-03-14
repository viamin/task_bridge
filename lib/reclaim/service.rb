# frozen_string_literal: true

require_relative "task"
require_relative "../base/service"

module Reclaim
  # Reclaim sync is currently unsupported since the API is not public and
  # this is not expected to work
  class Service < Base::Service
    def initialize(options:)
      super
      @api_key = ENV.fetch("RECLAIM_API_KEY", nil)
    end

    def friendly_name
      "Reclaim"
    end

    def sync_from_primary(primary_service)
      return @last_sync_data unless should_sync?

      primary_tasks = primary_service.tasks_to_sync(tags: [friendly_name])
      reclaim_tasks = tasks_to_sync
      unless options[:quiet]
        progressbar = ProgressBar.create(
          format: "%t: %c/%C |%w>%i| %e ",
          total: primary_tasks.length,
          title: "Reclaim Tasks"
        )
      end
      primary_tasks.each do |primary_task|
        output = if (existing_task = reclaim_tasks.find { |reclaim_task| friendly_titles_match?(reclaim_task, primary_task) })
          update_task(existing_task, primary_task)
        else
          add_task(primary_task) unless primary_task.completed
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{primary_tasks.length} #{options[:primary]} items to Reclaim Tasks" unless options[:quiet]
      { service: friendly_name, last_attempted: options[:sync_started_at], last_successful: options[:sync_started_at], items_synced: primary_tasks.length }.stringify_keys
    end

    # Reclaim doesn't use tags or an inbox, so just get all tasks that the user has access to
    def tasks_to_sync(*)
      list_tasks.map { |reclaim_task| Task.new(reclaim_task:, options:) }
    end
    memo_wise :tasks_to_sync

    def add_task(external_task)
      debug("external_task: #{external_task}") if options[:debug]
      request_body = { body: external_task.to_reclaim }
      if options[:pretend]
        "Would have added #{external_task.title} to Reclaim"
      else
        response = HTTParty.post("#{base_url}/tasks", authenticated_options.merge(request_body))
        if response.success?
          JSON.parse(response.body)
        else
          debug(response) if options[:debug]
          "Failed to create a Reclaim task - check api key"
        end
      end
    end

    def update_task(reclaim_task, external_task)
      debug("reclaim_task: #{reclaim_task.title}") if options[:debug]
      request_body = { body: external_task.to_reclaim.to_json }
      if options[:pretend]
        "Would have updated task #{external_task.title} in Reclaim"
      else
        response = HTTParty.patch("#{base_url}/tasks/#{reclaim_task.id}", authenticated_options.merge(request_body))
        if response.success?
          JSON.parse(response.body)
        else
          debug(response.body) if options[:debug]
          "Failed to update Reclaim task ##{reclaim_task.id} with code #{response.code} - check api key"
        end
      end
    end

    private

    # a helper method to fix bad syncs
    def delete_all_tasks
      tasks = list_tasks
      progressbar = ProgressBar.create(format: " %c/%C |%w>%i| %e ", total: tasks.length)
      tasks.each do |task|
        delete_task(task["id"])
        sleep 0.5
        progressbar.increment
      end
      puts "Deleted #{tasks.count} tasks"
    end

    def delete_task(task_id)
      HTTParty.delete("#{base_url}/planner/policy/task/#{task_id}", authenticated_options)
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
      raise "Error loading Reclaim tasks - check api key" unless response.success?

      JSON.parse(response.body)
    end
    memo_wise :list_tasks

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
      "https://api.app.reclaim.ai/api"
    end
  end
end
