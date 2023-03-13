# frozen_string_literal: true

require_relative "authentication"
require_relative "issue"
require_relative "../base/service"

module Github
  # A service class to connect to the Github API
  class Service < Base::Service
    attr_reader :authentication

    def initialize(options:)
      @authentication = Authentication.new(options).authenticate!
      super
    rescue StandardError
      # If authentication fails, skip the service
      nil
    end

    def friendly_name
      "Github"
    end

    # By default Github syncs TO the primary service
    def sync_to_primary(primary_service)
      issues = issues_to_sync(options[:tags])
      existing_tasks = primary_service.tasks_to_sync(tags: [friendly_name], inbox: true)
      unless options[:quiet]
        progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: issues.length,
                                         title: "Github issues")
      end
      issues.each do |issue|
        debug("Looking for #{issue.friendly_title} (#{issue.status})") if options[:debug]
        output = if (existing_task = existing_tasks.find do |task|
                       issue.friendly_title.downcase == task.title.downcase.strip
                     end)
          if should_sync?(issue.updated_at)
            primary_service.update_task(existing_task, issue)
          elsif options[:debug]
            debug("Skipping sync of #{issue.title} (should_sync? == false)")
          end
        elsif issue.open?
          primary_service.add_task(issue, options)
        end
        progressbar.log "#{self.class}##{__method__}: #{output}" if !output.blank? && ((options[:pretend] && options[:verbose] && !options[:quiet]) || options[:debug])
        progressbar.increment unless options[:quiet]
      end
      puts "Synced #{issues.length} Github issues to #{options[:primary]}" unless options[:quiet]
      { service: friendly_name, last_attempted: options[:sync_started_at], last_successful: options[:sync_started_at], items_synced: issues.length }.stringify_keys
    end

    private

    # the minimum time we should wait between syncing tasks
    def min_sync_interval
      60.minutes.to_i
    end

    def authenticated_options
      {
        headers: {
          accept: "application/vnd.github+json",
          authorization: "Bearer #{authentication['access_token']}"
        }
      }
    end

    def sync_repositories(with_url: false)
      repos = options[:repositories]
      if with_url
        repos.map { |repo| "https://api.github.com/repos/#{repo}" }
      else
        repos
      end
    end

    def issues_to_sync(tags = nil)
      tagged_issues = sync_repositories
                      .map { |repo| list_issues(repo, tags) }
                      .flatten
                      .map { |issue| Issue.new(github_issue: issue, options:) }
      assigned_issues = list_assigned
                        .filter { |issue| sync_repositories(with_url: true).include?(issue["repository_url"]) }
                        .map { |issue| Issue.new(github_issue: issue, options:) }
      (tagged_issues + assigned_issues).uniq(&:id)
    end
    memo_wise :issues_to_sync

    # https://docs.github.com/en/rest/issues/issues#list-issues-assigned-to-the-authenticated-user
    # For some reason this API call doesn't always return
    # all of my assigned issues, and I don't know why
    def list_assigned
      @list_assigned ||= begin
        query = {
          query: {
            state: "all",
            per_page: "100"
          }
        }
        response = HTTParty.get("https://api.github.com/issues", authenticated_options.merge(query))
        JSON.parse(response.body) if response.success?
      end
    end
    memo_wise :list_assigned

    # https://docs.github.com/en/rest/issues/issues#list-repository-issues
    def list_issues(repository, tags = nil)
      query = {
        query: {
          state: "all",
          labels: (tags || options[:tags]).join(","),
          since: Chronic.parse("2 days ago").iso8601,
          per_page: "100"
        }
      }
      response = HTTParty.get("https://api.github.com/repos/#{repository}/issues", authenticated_options.merge(query))
      raise "Error loading Github issues - check repository name and access (response code: #{response.code}" unless response.success?

      JSON.parse(response.body)
    end
    memo_wise :list_issues

    def issue_labels(issue)
      issue["labels"].map { |label| label["name"] }
    end
    memo_wise :issue_labels
  end
end
