# frozen_string_literal: true

# == Schema Information
#
# Table name: sync_items
#
#  id                 :integer          not null, primary key
#  completed          :boolean
#  completed_at       :datetime
#  completed_on       :datetime
#  due_at             :datetime
#  due_date           :datetime
#  flagged            :boolean
#  item_type          :string
#  last_modified      :datetime
#  notes              :string
#  start_at           :datetime
#  start_date         :datetime
#  status             :string
#  title              :string
#  type               :string
#  url                :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  external_id        :string
#  parent_item_id     :integer
#  sync_collection_id :integer
#
# Indexes
#
#  index_sync_items_on_parent_item_id      (parent_item_id)
#  index_sync_items_on_sync_collection_id  (sync_collection_id)
#
# Foreign Keys
#
#  parent_item_id      (parent_item_id => sync_items.id)
#  sync_collection_id  (sync_collection_id => sync_collections.id)
#

module Github
  # A representation of a Github issue
  class Issue < Base::SyncItem
    include Collectible

    attr_accessor :github_issue
    attr_reader :number, :tags, :project, :is_pr

    def read_original(only_modified_dates: false)
      super(only_modified_dates: only_modified_dates)
      @number = read_attribute(github_issue, "number", only_modified_dates:)
      # Add "Github" to the labels
      @tags = (default_tags + github_issue["labels"].map { |label| label["name"] }).uniq
      @project = github_issue["project"] || short_repo_name(github_issue)
      @is_pr = (github_issue["pull_request"] && !github_issue["pull_request"]["diff_url"].nil?) || false
      self.last_modified = Chronic.parse(github_issue["updated_at"])&.getlocal
      self
    end

    def external_data
      github_issue
    end

    def provider
      "Github"
    end

    def completed?
      status == "closed"
    end

    def open?
      status == "open"
    end

    def friendly_title
      "#{project}-##{number}: #{is_pr ? "[PR] " : ""}#{title.strip}"
    end

    def sync_notes
      url
    end

    class << self
      def attribute_map
        {
          status: "state",
          tags: nil,
          url: "html_url",
          notes: "body",
          last_modified: nil
        }
      end
    end

    private

    def short_repo_name(github_issue)
      github_issue["repository_url"].split("/").last
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
    #       "url" => "https://api.github.com/repos/viamin/task_bridge/issues/11/reactions",
    #       "total_count" => 0,
    #       "+1" => 0,
    #       "-1" => 0,
    #       "laugh" => 0,
    #       "hooray" => 0,
    #       "confused" => 0,
    #       "heart" => 0,
    #       "rocket" => 0,
    #      "eyes" => 0
    #     },
    #     "timeline_url" => "https://api.github.com/repos/viamin/task_bridge/issues/11/timeline",
    #     "performed_via_github_app" => nil,
    #     "state_reason" => nil
    #   }
  end
end
