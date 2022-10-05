require_relative "task"

module Reclaim
  class Service
    attr_reader :options

    def initialize(options)
      @options = options
      @auth_cookie = ENV.fetch("RECLAIM_AUTH_TOKEN", nil)
    end

    def sync(primary_service)
      tasks = primary_service.tasks_to_sync(["Reclaim"])
      existing_tasks = tasks_to_sync
      progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: tasks.length, title: "Reclaim Tasks") if options[:verbose] || options[:debug]
      tasks.each do |task|
        output = if (existing_task = existing_tasks.find { |t| task_title_matches(t, task) })
          # update the existing task
          update_task(existing_task, task)
        else
          # add a new task
          add_task(task)
        end
        progressbar.log output if options[:debug]
        progressbar.increment if options[:verbose] || options[:debug]
      end
      puts "Synced #{tasks.length} #{options[:primary]} tasks to Reclaim Tasks" if options[:verbose]
    end

    # No-op for now
    def purge
      false
    end

    def add_task(task)
      puts "Called #{self.class}##{__method__}" if options[:debug]
      request_body = {body: task.to_json}
      if options[:pretend]
        "Would have added #{task.title} to Reclaim"
      else
        response = HTTParty.post("#{base_url}/tasks", authenticated_options.merge(request_body))
        if response.code == 200
          JSON.parse(response.body)
        else
          puts "Failed to create a Reclaim task - check auth cookie"
          nil
        end
      end
    end

    def update_task(existing_task, task)
      puts "Called #{self.class}##{__method__}" if options[:debug]
      request_body = {body: task.to_json}
      if options[:pretend]
        "Would have updated task #{task.title} in Reclaim"
      else
        response = HTTParty.put("#{base_url}/tasks/#{existing_task.id}", authenticated_options.merge(request_body))
        if response.code == 200
          JSON.parse(response.body)
        else
          puts "Failed to update Reclaim task ##{existing_task.id} with code #{response.code} - check auth cookie"
          puts response.body if options[:verbose]
          nil
        end
      end
    end

    private

    def tasks_to_sync
      list_tasks.map { |reclaim_task| Task.new(reclaim_task, options) }
    end

    def task_title_matches(task, other_task)
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
      if response.code == 200
        JSON.parse(response.body)
      else
        raise "Error loading Reclaim tasks - check cookie expiration"
      end
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
