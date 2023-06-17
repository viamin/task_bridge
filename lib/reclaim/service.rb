# frozen_string_literal: true

require_relative "task"
require_relative "../base/service"

module Reclaim
  # Reclaim sync is currently unsupported since the API is not public and
  # this is not expected to work
  class Service < Base::Service
    def initialize(options:)
      super
      @api_key = Chamber.dig(:reclaim, :api_key)
    end

    def item_class
      Task
    end

    def friendly_name
      "Reclaim"
    end

    def sync_strategies
      [:from_primary]
    end

    # Reclaim doesn't use tags or an inbox, so just get all tasks that the user has access to
    def items_to_sync(*)
      list_tasks.map { |reclaim_task| Task.new(reclaim_task:, options:) }
    end
    memo_wise :items_to_sync

    def add_item(external_task)
      debug("external_task: #{external_task}", options[:debug])
      request_body = { body: Task.from_external(external_task) }
      if options[:pretend]
        "Would have added #{external_task.title} to Reclaim"
      else
        response = HTTParty.post("#{base_url}/tasks", authenticated_options.merge(request_body))
        if response.success?
          new_item = JSON.parse(response.body)
          update_sync_data(external_task, new_item["id"])
        else
          debug(response, options[:debug])
          "Failed to create a Reclaim task - check api key"
        end
      end
    end

    # Reclaim doesn't support PATCH semantics, so we need to do a PUT
    def patch_item(reclaim_task, attributes_hash)
      debug("reclaim_task: #{reclaim_task.title}, attributes_hash: #{attributes_hash.pretty_inspect}", options[:debug])
      put_request_body = { body: reclaim_task.to_h.merge(attributes_hash).to_json }
      put_response = HTTParty.put("#{base_url}/tasks/#{reclaim_task.id}", authenticated_options.merge(put_request_body))
      return if put_response.success?

      debug(response.body, options[:debug])
      "Failed to update Reclaim task ##{reclaim_task.id} with code #{response.code} - check api key"
    end

    def update_item(reclaim_task, external_task)
      debug("reclaim_task: #{reclaim_task.title}", options[:debug])
      request_body = { body: Task.from_external(external_task).to_json }
      if options[:pretend]
        "Would have updated task #{external_task.title} in Reclaim"
      else
        response = HTTParty.patch("#{base_url}/tasks/#{reclaim_task.id}", authenticated_options.merge(request_body))
        if response.success?
          update_sync_data(external_task, reclaim_task.id) if options[:update_ids_for_existing]
          JSON.parse(response.body)
        else
          debug(response.body, options[:debug])
          "Failed to update Reclaim task ##{reclaim_task.id} with code #{response.code} - check api key"
        end
      end
    end

    private

    def min_sync_interval
      15.minutes.to_i
    end

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
