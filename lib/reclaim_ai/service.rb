require_relative "task"

module ReclaimAi
  class Service
    def initialize(options)
      @options = options
    end

    def sync
    end

    def purge
    end

    def add_task(task, options = {})
    end

    def update_task(existing_task, task, options = {})
    end

    private
  end
end
