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
      issues = issues_to_sync(["Github"])
      existing_tasks = primary_service.tasks_to_sync(inbox: true)
      progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: issues.length, title: "Github issues") if options[:verbose]
      issues.each do |issue|
        output = if (existing_task = existing_tasks.find { |task| issue.task_title.downcase == task.title.downcase })
          # update the existing task
          primary_service.update_task(existing_task, issue, options)
        elsif issue.open?
          # add a new task
          primary_service.add_task(issue, options)
        end
        progressbar.log output if !output.blank? && ((options[:pretend] && options[:verbose]) || options[:debug])
        progressbar.increment if options[:verbose]
      end
      puts "Synced #{issues.length} Github issues to #{options[:primary]}" if options[:verbose]
    end

    # Not currently supported for this service
    def prune
      false
    end

    private

    def authenticated_options
      {
        headers: {
          accept: "application/vnd.github+json",
          authorization: "Bearer #{authentication["access_token"]}"
        }
      }
    end

    def sync_repositories(with_url = false)
      repos = ENV.fetch("GITHUB_REPOSITORIES", []).split(",")
      if with_url
        repos.map { |repo| "https://api.github.com/repos/#{repo}" }
      else
        repos
      end
    end

    def issues_to_sync(tags = nil)
      tagged_issues = sync_repositories.map { |repo| list_issues(repo, tags) }.flatten.map { |issue| Issue.new(issue, options) }
      assigned_issues = list_assigned.filter { |issue| sync_repositories(true).include?(issue["repository_url"]) }.map { |issue| Issue.new(issue, options) }
      (tagged_issues + assigned_issues).uniq
    end

    # github api reference:
    # https://docs.github.com/en/rest/repos/repos#list-repositories-for-the-authenticated-user
    # def list_repositories
    #   response = HTTParty.get("https://api.github.com/user/repos", authenticated_options)
    #   JSON.parse(response.body)
    # end

    def list_assigned
      query = {
        query: {
          state: "all",
          per_page: 100
        }
      }
      response = HTTParty.get("https://api.github.com/issues", authenticated_options.merge(query))
      if response.code == 200
        JSON.parse(response.body)
      end
    end

    # https://docs.github.com/en/rest/issues/issues#list-repository-issues
    def list_issues(repository, tags = nil)
      query = {
        query: {
          state: "all",
          labels: (tags || options[:tags]).join(","),
          since: Chronic.parse("2 days ago").iso8601
        }
      }
      response = HTTParty.get("https://api.github.com/repos/#{repository}/issues", authenticated_options.merge(query))
      if response.code == 200
        JSON.parse(response.body)
      else
        raise "Error loading Github issues - check repository name and access (response code: #{response.code}"
      end
    end

    def issue_labels(issue)
      issue["labels"].map { |label| label["name"] }
    end
  end
end
