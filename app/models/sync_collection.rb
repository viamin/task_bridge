# frozen_string_literal: true

# == Schema Information
#
# Table name: sync_collections
#
#  id          :integer          not null, primary key
#  last_synced :datetime
#  title       :string
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
class SyncCollection < ApplicationRecord
  has_one :asana_task
  has_one :google_tasks_task
  has_one :omnifocus_task
  has_one :github_issue
  has_one :instapaper_article
  has_one :omnifocus_task
  has_one :reclaim_task
  has_one :reminders_reminder

  def items
    [
      asana_task,
      google_tasks_task,
      omnifocus_task,
      github_issue,
      instapaper_article,
      omnifocus_task,
      reclaim_task,
      reminders_reminder
    ].compact
  end

  def <<(sync_item)
    sync_item.sync_collection_id = id
    sync_item.save!
  end

  def needs_sync?
    last_synced.nil? ||
      items.any? { |item| item.last_modified > last_synced }
  end
end
