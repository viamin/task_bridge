# frozen_string_literal: true

require_relative "authentication"
require_relative "issue"
require_relative "../base/service"

module Github
  # A service class to connect to the Github API
  class Service < Base::Service
    include GlobalOptions

    attr_reader :authentication

    def initialize
      super
      @authentication = Authentication.new(options).authenticate!
    rescue
      # If authentication fails, skip the service
      nil
    end

    def item_class
      Issue
    end

    def friendly_name
      "Github"
    end

    def sync_strategies
      [:to_primary]
    end

    def items_to_sync(tags: nil)
      tagged_issues = sync_repositories
        .map { |repo| list_issues(repo, tags) }
        .flatten
        .map { |issue| Issue.new(github_issue: issue, options:) }
      assigned_issues = list_assigned
        .filter { |issue| sync_repositories(with_url: true).include?(issue["repository_url"]) }
        .map { |issue| Issue.new(github_issue: issue, options:) }
      (tagged_issues + assigned_issues).uniq(&:id)
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
          authorization: "Bearer #{authentication["access_token"]}"
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

    def issue_labels(issue)
      issue["labels"].map { |label| label["name"] }
    end
  end
end
