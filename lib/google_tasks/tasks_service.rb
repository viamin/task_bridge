require "google/apis/tasks_v1"
require_relative "base_cli"

module GoogleTasks
  # A service class to connect to the Google Tasks API
  class TasksService < BaseCli
    attr_reader :tasks_service

    def initialize
      @tasks_service = Google::Apis::TasksV1::TasksService.new
      @tasks_service.authorization = user_credentials_for(Google::Apis::TasksV1::AUTH_TASKS)
    end

    def add_task(omnifocus_task, list)
    end
  end
end
