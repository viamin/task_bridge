require_relative "authentication"
require_relative "issue"

module Github
  # A service class to connect to the Github API
  class Service
    attr_reader :options, :authentication

    def initialize(options)
      @options = options
      @authentication = Authentication.new(options).authenticate
    end

    # By default Github syncs TO the primary service
    def sync(primary_service)
      issues = issues_to_sync
      existing_tasks = primary_service.tasks_to_sync
      progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: issues.length, title: "Github issues") if options[:verbose]
      issues.each do |issue|
        if (existing_task = existing_tasks.find { |task| issue.task_title.downcase == task.title.downcase })
          # update the existing task
          primary_service.update_task(existing_task, issue, options)
        else
          # add a new task
          primary_service.add_task(issue, options) if issue.open?
        end
        progressbar.increment if options[:verbose]
      end
      puts "Synced #{issues.length} Github issues to #{options[:primary]}" if options[:verbose]
    end

    private

    def authenticated_options
      {
        headers: {
          accept: "application/vnd.github+json",
          authorization: "Bearer #{authentication["access_token"]}"
        },
        query: {
          state: "all",
          labels: options[:tags].join(",")
        }
      }
    end

    def issues_to_sync
      # repos = list_repositories.filter { |repo| options[:repositories].include?(repo["full_name"]) }
      issues = options[:repositories].map { |repo| list_issues(repo) }.flatten
      issues.map { |issue| Issue.new(issue) }
    end

    # github api reference:
    # https://docs.github.com/en/rest/repos/repos#list-repositories-for-the-authenticated-user
    # def list_repositories
    #   response = HTTParty.get("https://api.github.com/user/repos", authenticated_options)
    #   JSON.parse(response.body)
    # end

    # https://docs.github.com/en/rest/issues/issues#list-repository-issues
    def list_issues(repository)
      response = HTTParty.get("https://api.github.com/repos/#{repository}/issues", authenticated_options)
      if response.code == 200
        JSON.parse(response.body)
      else
        raise "Error loading issues - check repository name and access"
      end
    end

    def issue_labels(issue)
      issue["labels"].map { |label| label["name"] }
    end
  end
end
