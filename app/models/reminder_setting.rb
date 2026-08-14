class ReminderSetting < ApplicationRecord
  CATALOG = {
    'slack_signup' => {
      name: 'Slack signup reminder',
      description: 'Gentle reminder to active members without a linked Slack account.',
      enabled: false
    },
    'application_link' => {
      name: 'Application link reminder',
      description: 'Reminder when someone requested a membership application link but has not submitted yet.',
      enabled: false
    },
    'payment_overdue' => {
      name: 'Overdue payment reminder',
      description: 'Weekly reminder to members whose dues are past due. Members who have cancelled are not reminded.',
      enabled: false
    },
    'orientation' => {
      name: 'Orientation reminder',
      description: 'Reminder to approved members who have not had their building access orientation yet.',
      enabled: false
    }
  }.freeze

  validates :key, presence: true, uniqueness: true
  validates :name, presence: true

  scope :ordered, -> { order(:name) }

  def self.enabled?(key)
    find_by(key: key)&.enabled? == true
  end

  def self.seed_defaults!
    CATALOG.each do |key, attrs|
      find_or_create_by!(key: key) do |setting|
        setting.assign_attributes(attrs)
      end
    end
  end
end
