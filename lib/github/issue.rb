module Github
  # A representation of a Github issue
  class Issue
    attr_reader :options, :id, :title, :html_url, :number, :labels, :state, :project, :is_pr

    def initialize(github_issue, options)
      @options = options
      @url = github_issue["url"]
      @html_url = github_issue["html_url"]
      @id = github_issue["id"]
      @number = github_issue["number"]
      @title = github_issue["title"]
      # Add "Github" to the labels
      @labels = (github_issue["labels"].map { |label| label["name"] }).push("Github").uniq
      @state = github_issue["state"]
      @project = github_issue["project"] || short_repo_name(github_issue)
      @is_pr = (github_issue["pull_request"] && !github_issue["pull_request"]["diff_url"].nil?) || false
    end

    def completed?
      state == "closed"
    end

    def open?
      state == "open"
    end

    def task_title
      "#{project}-##{number}: #{is_pr ? "[PR] " : ""}#{title}"
    end

    def properties
      {
        name: task_title,
        note: html_url
      }
    end

    def tags
      labels
    end

    private

    def short_repo_name(github_issue)
      github_issue["repository_url"].split("/").last.camelize
    end

    # Raw:
    #   {
    #     "url" => "https://api.github.com/repos/viamin/task_bridge/issues/11",
    #     "repository_url" => "https://api.github.com/repos/viamin/task_bridge",
    #     "labels_url" => "https://api.github.com/repos/viamin/task_bridge/issues/11/labels{/name}",
    #     "comments_url" => "https://api.github.com/repos/viamin/task_bridge/issues/11/comments",
    #     "events_url" => "https://api.github.com/repos/viamin/task_bridge/issues/11/events",
    #     "html_url" => "https://github.com/viamin/task_bridge/issues/11",
    #     "id" => 1391640649,
    #     "node_id" => "I_kwDOIDh6us5S8sBJ",
    #     "number" => 11,
    #     "title" => "Completed OmniFocus tasks are being synced as new, active tasks",
    #     "user" => {
    #       "login" => "viamin",
    #       "id" => 260794,
    #       "node_id" => "MDQ6VXNlcjI2MDc5NA==",
    #       "avatar_url" => "https://avatars.githubusercontent.com/u/260794?v=4",
    #       "gravatar_id" => "",
    #       "url" => "https://api.github.com/users/viamin",
    #       "html_url" => "https://github.com/viamin",
    #       "followers_url" => "https://api.github.com/users/viamin/followers",
    #       "following_url" => "https://api.github.com/users/viamin/following{/other_user}",
    #       "gists_url" => "https://api.github.com/users/viamin/gists{/gist_id}",
    #       "starred_url" => "https://api.github.com/users/viamin/starred{/owner}{/repo}",
    #       "subscriptions_url" => "https://api.github.com/users/viamin/subscriptions",
    #       "organizations_url" => "https://api.github.com/users/viamin/orgs",
    #       "repos_url" => "https://api.github.com/users/viamin/repos",
    #       "events_url" => "https://api.github.com/users/viamin/events{/privacy}",
    #       "received_events_url" => "https://api.github.com/users/viamin/received_events",
    #       "type" => "User",
    #       "site_admin" => false
    #     },
    #     "labels" => [],
    #     "state" => "open",
    #     "locked" => false,
    #     "assignee" => nil,
    #     "assignees" => [],
    #     "milestone" => nil,
    #     "comments" => 0,
    #     "created_at" => "2022-09-30T00:08:28Z",
    #     "updated_at" => "2022-09-30T00:08:28Z",
    #     "closed_at" => nil,
    #     "author_association" => "OWNER",
    #     "active_lock_reason" => nil,
    #     "body" =>
    # "After a sync, tasks that have been marked complete in Omnifocus are showing up as to do in Google tasks. Also, the due dates appear to be incorrect (for example, an omnifocus task with a due date of today at 9pm shows up as due tomorrow (with no time) in Google Tasks. ",
    #     "reactions" => {
    #       "url" => "https://api.github.com/repos/viamin/task_bridge/issues/11/reactions", "total_count" => 0, "+1" => 0, "-1" => 0, "laugh" => 0, "hooray" => 0, "confused" => 0, "heart" => 0, "rocket" => 0, "eyes" => 0
    #     },
    #     "timeline_url" => "https://api.github.com/repos/viamin/task_bridge/issues/11/timeline",
    #     "performed_via_github_app" => nil,
    #     "state_reason" => nil
    #   }
  end
end
