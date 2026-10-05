# frozen_string_literal: true

module Github
  # A service class to connect to the Github API
  class Service < Base::Service
    class ActivityFetchError < StandardError; end

    include GlobalOptions

    attr_reader :authentication, :authorized

    def initialize(options: nil)
      super
      @activity_sync_retrieved = false
      @activity_sync_succeeded = true
      @authentication = Authentication.new.authenticate!
      @authorized = true
    rescue StandardError => e
      # If authentication fails, skip the service
      puts "Github authentication failed: #{e.message}" unless self.options[:quiet]
      @authentication = nil
      @authorized = false
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

    def deletion_detection_strategy
      # Issue queries are filtered (labels, updated-since window) and the
      # assigned-issues endpoint is known-incomplete, so absence proves
      # nothing. GitHub provides no tombstone or per-issue deletion event to
      # verify against, so detection stays disabled (#220).
      Disappearance::Strategy.disabled
    end

    def items_to_sync(*, tags: nil, only_modified_dates: false)
      external_issues = sync_repositories.flat_map { |repo| list_issues(repo, tags) }
      external_issues.concat(list_assigned.select { |issue| configured_issue?(issue) })
      external_issues.uniq { |issue| issue[Issue.external_attribute_map[:external_id]] }.map do |external_issue|
        refresh_issue(external_issue, only_modified_dates:).tap do |issue|
          publish_activity_for(issue, external_issue)
        end
      end
    end

    # Whether this run retrieved activity and all related emissions completed
    # without an ActivityFetchError or outbox enqueue failure (#224).
    # lib/tasks/sync.rake reads this to decide whether to advance the
    # activity-sync cursor; skipped task syncs must retain their window.
    def activity_emit_complete?
      @activity_sync_retrieved && @activity_sync_succeeded
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
      repos = Array(options[:repositories])
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
      return @list_assigned if defined?(@list_assigned)

      @list_assigned = begin
        query = {
          query: {
            state: "all",
            per_page: "100"
          }
        }
        response = HTTParty.get("https://api.github.com/issues", authenticated_options.merge(query))
        JSON.parse(response.body) if response.success?
      end
      @list_assigned || []
    end

    # https://docs.github.com/en/rest/issues/issues#list-repository-issues
    def list_issues(repository, tags = nil)
      query = {
        query: {
          state: "all",
          labels: (tags || options[:tags]).join(","),
          since: (last_successful_sync_at || Chronic.parse("2 days ago")).iso8601,
          per_page: "100"
        }
      }
      response = HTTParty.get("https://api.github.com/repos/#{repository}/issues", authenticated_options.merge(query))
      raise "Error loading Github issues - check repository name and access (response code: #{response.code})" unless response.success?

      JSON.parse(response.body)
    end

    def refresh_issue(external_issue, only_modified_dates:)
      issue = Issue.find_or_initialize_by_source(
        service_name: service_name,
        external_id: external_issue[Issue.external_attribute_map[:external_id]]
      )
      issue.options = self.class.build_options(issue.options, service_name)
      issue.github_issue = external_issue
      issue.refresh_from_external!(only_modified_dates:)
    end

    def publish_activity_for(issue, external_issue)
      return unless issue.persisted?

      updated_at = external_issue["updated_at"]
      return if updated_at.present? && Time.iso8601(updated_at) < activity_since

      @activity_sync_retrieved = true
      events = timeline_events(external_issue)
      events.concat(review_events(external_issue)) if issue.is_pr
      @activity_sync_succeeded = false unless ActivityEmitter.emit_for(issue, events:, since: activity_since)
    rescue ActivityFetchError => e
      @activity_sync_succeeded = false
      puts "Github activity fetch failed: #{e.message}" unless options[:quiet]
    end

    # Timeline and review APIs do not accept a `since` filter. Start at the
    # newest page and follow `next` links until the cursor bounds the search.
    def timeline_events(external_issue)
      activity_events("#{issue_api_url(external_issue)}/timeline")
    end

    def review_events(external_issue)
      activity_events("#{repository_api_url(external_issue)}/pulls/#{external_issue['number']}/reviews")
        .map { |review| review.merge("activity_type" => "reviewed") }
    end

    def activity_events(url)
      response = get_activity_page(url)
      ensure_activity_response!(response, url)

      events = parsed_activity_response(response)
      while (next_url = pagination_url(response, "next"))
        response = get_paginated_activity_page(next_url)
        ensure_activity_response!(response, next_url)
        page_events = parsed_activity_response(response)
        events.concat(page_events)
        break if page_before_activity_since?(page_events)
      end
      events
    end

    def get_activity_page(url)
      HTTParty.get(url, authenticated_options.merge(query: { per_page: "100" }))
    end

    def get_paginated_activity_page(url)
      HTTParty.get(url, authenticated_options)
    end

    def parsed_activity_response(response)
      JSON.parse(response.body)
    end

    def ensure_activity_response!(response, url)
      return if response.success?

      raise ActivityFetchError, "Error loading Github activity from #{url} (response code: #{response.code})"
    end

    def pagination_url(response, relation)
      headers = response.headers || {}
      link = headers["link"] || headers["Link"]
      link.match(/<([^>]+)>;\s*rel="#{relation}"/)&.captures&.first if link
    end

    def page_before_activity_since?(events)
      timestamps = events.filter_map { |event| event_occurred_at(event).presence }
      timestamps.present? && timestamps.all? { |timestamp| Time.iso8601(timestamp) < activity_since }
    end

    def event_occurred_at(event)
      event["created_at"] || event["submitted_at"] || event["updated_at"]
    end

    def activity_since
      @activity_since ||= last_successful_activity_sync_at || last_successful_sync_at || Chronic.parse("2 days ago")
    end

    def last_successful_activity_sync_at
      sync_state&.last_successful_activity_sync_at
    end

    def issue_api_url(issue)
      issue["url"] || "#{repository_api_url(issue)}/issues/#{issue['number']}"
    end

    def repository_api_url(issue)
      issue.fetch("repository_url")
    end

    def configured_issue?(issue)
      sync_repositories(with_url: true).include?(issue["repository_url"])
    end

    def issue_labels(issue)
      issue["labels"].map { |label| label["name"] }
    end
  end
end
