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
  has_one :asana_task, class_name: "Asana::Task", foreign_key: :sync_collection_id,
                       dependent: :nullify, inverse_of: false
  has_one :google_tasks_task, class_name: "GoogleTasks::Task", foreign_key: :sync_collection_id,
                              dependent: :nullify, inverse_of: false
  has_one :omnifocus_task, class_name: "Omnifocus::Task", foreign_key: :sync_collection_id,
                           dependent: :nullify, inverse_of: false
  has_one :github_issue, class_name: "Github::Issue", foreign_key: :sync_collection_id,
                         dependent: :nullify, inverse_of: false
  has_one :instapaper_article, class_name: "Instapaper::Article", foreign_key: :sync_collection_id,
                               dependent: :nullify, inverse_of: false
  has_one :reclaim_task, class_name: "Reclaim::Task", foreign_key: :sync_collection_id,
                         dependent: :nullify, inverse_of: false
  has_one :reminders_reminder, class_name: "Reminders::Reminder", foreign_key: :sync_collection_id,
                               dependent: :nullify, inverse_of: false

  def items
    [
      asana_task,
      google_tasks_task,
      omnifocus_task,
      github_issue,
      instapaper_article,
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
      items.any? { |item| item.last_modified.present? && item.last_modified > last_synced }
  end
end
