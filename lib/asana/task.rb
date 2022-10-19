# frozen_string_literal: true

module Asana
  # A representation of an Asana task
  class Task
    attr_reader :options, :id, :title, :html_url, :tags, :completed, :project, :due_date, :due_at, :updated_at, :hearted, :notes, :type, :start_date, :start_at

    def initialize(asana_task, options)
      @options = options
      @id = asana_task["gid"]
      @title = asana_task["name"]
      @html_url = asana_task["permalink_url"]
      @tags = default_tags
      @completed = asana_task["completed"]
      @completed_at = Chronic.parse(asana_task["completed_at"])
      @project = asana_task["projects"].select { |project| project[:name] == options[:project] }
      @due_date = Chronic.parse(asana_task["due_on"])
      @due_at = Chronic.parse(asana_task["due_at"])
      @updated_at = Chronic.parse(asana_task["modified_at"])
      @hearted = asana_task["hearted"]
      @notes = asana_task["notes"]
      @type = asana_task["resource_type"]
      @start_date = Chronic.parse(asana_task["start_on"])
      @start_at = Chronic.parse(asana_task["start_at"])
    end

    def self.requested_fields
      %w[name permalink_url completed completed_at projects due_on due_at modified_at hearted notes start_on start_at]
    end

    def completed?
      completed
    end

    def open?
      !completed?
    end

    def task_title
      title.strip
    end

    # Fields required for primary service
    def properties
      {
        name: task_title,
        note: html_url,
        flagged: hearted,
        completion_date: completed_at,
        defer_date: start_at || start_date,
        due_date: due_at || due_date
      }.compact
    end

    # fields required for Asana
    def to_json(*)
      {
        data: {
          completed: completed?,
          due_at: due_at&.iso8601,
          due_on: due_date&.to_date&.iso8601,
          liked: hearted,
          notes:,
          name: title,
          start_at: start_at&.iso8601,
          start_on: start_date&.to_date&.iso8601,
          projects: [project["gid"]]
        }
      }.compact.to_json
    end

    private

    def default_tags
      options[:tags] + ["Asana"]
    end

    # {
    #   data: {
    #     gid: "1203188830269587",
    #     assignee: null,
    #     assignee_status: "upcoming",
    #     completed: false,
    #     completed_at: null,
    #     created_at: "2022-10-18T05:45:35.090Z",
    #     due_at: "2022-10-19T05:30:00.000Z",
    #     due_on: "2022-10-18",
    #     followers: [
    #       {
    #         gid: "1172102786176655",
    #         name: "Bart Agapinan",
    #         resource_type: "user"
    #       }
    #     ],
    #     hearted: false,
    #     hearts: [],
    #     liked: false,
    #     likes: [],
    #     memberships: [
    #       {
    #         project: {
    #           gid: "1203188830269576",
    #           name: "TaskBridge",
    #           resource_type: "project"
    #         },
    #         section: {
    #           gid: "1203188830269577",
    #           name: "Untitled section",
    #           resource_type: "section"
    #         }
    #       }
    #     ],
    #     modified_at: "2022-10-18T05:45:44.967Z",
    #     name: "Due Time Task",
    #     notes: "",
    #     num_hearts: 0,
    #     num_likes: 0,
    #     parent: null,
    #     permalink_url: "https://app.asana.com/0/1203188830269576/1203188830269587",
    #     projects: [
    #       {
    #         gid: "1203188830269576",
    #         name: "TaskBridge",
    #         resource_type: "project"
    #       }
    #     ],
    #     resource_type: "task",
    #     start_at: null,
    #     start_on: null,
    #     tags: [],
    #     resource_subtype: "default_task",
    #     workspace: {
    #       gid: "498346170860",
    #       name: "Personal Projects",
    #       resource_type: "workspace"
    #     }
    #   }
    # }
  end
end
