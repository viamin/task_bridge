# frozen_string_literal: true

class SyncCollection < ApplicationRecord
  has_one :asana_task
  has_one :google_tasks_task
  has_one :omnifocus_task
  has_one :github_issue
  has_one :instapaper_article
  has_one :omnifocus_task
  has_one :reclaim_task
  has_one :reminders_reminder
end
