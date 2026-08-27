class NotificationOptOut < ApplicationRecord
  belongs_to :user

  validates :category, presence: true, inclusion: { in: ->(_) { NotificationCategory::CATALOG.keys } }
  validates :channel, presence: true, inclusion: { in: NotificationCategory::CHANNELS }
  validates :source, presence: true, inclusion: { in: NotificationCategory::SOURCES }
  validates :user_id, uniqueness: { scope: %i[category channel] }

  scope :for_category, ->(category) { where(category: category) }
  scope :for_channel, ->(channel) { where(channel: channel) }

  def self.opted_out?(user, category:, channel: 'email')
    return false if user.blank?

    exists?(user: user, category: category, channel: channel)
  end

  def self.opt_out!(user, category:, channel: 'email', source: 'self_service')
    find_or_create_by!(user: user, category: category, channel: channel) do |record|
      record.source = source
    end
  end

  def self.opt_in!(user, category:, channel: 'email')
    where(user: user, category: category, channel: channel).delete_all
  end

  def self.opted_out_user_ids(category:, channel: 'email')
    where(category: category, channel: channel).select(:user_id)
  end

  def self.count_for_reminder(reminder_key)
    category = NotificationCategory.reminder_backed.find { |entry| entry.reminder_key == reminder_key }&.key
    return 0 unless category

    for_category(category).distinct.count(:user_id)
  end
end
