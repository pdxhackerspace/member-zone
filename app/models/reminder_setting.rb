class ReminderSetting < ApplicationRecord
  CATALOG = {
    'slack_signup' => {
      name: 'Slack signup reminder',
      description: 'Gentle reminder to active members without a linked Slack account.',
      enabled: false,
      allow_opt_out: true
    },
    'application_link' => {
      name: 'Application link reminder',
      description: 'Reminder when someone requested a membership application link but has not submitted yet.',
      enabled: false,
      allow_opt_out: true
    },
    'payment_overdue' => {
      name: 'Overdue payment reminder',
      description: 'Weekly reminder to members whose dues are past due. Members who have cancelled are not reminded.',
      enabled: false,
      allow_opt_out: true
    },
    'orientation' => {
      name: 'Orientation reminder',
      description: 'Reminder to approved members who have not had their building access orientation yet.',
      enabled: false,
      allow_opt_out: true
    },
    'parking_notices' => {
      name: 'Parking notice reminders',
      description: 'Pre-expiration, expiration, and follow-up reminders for parking permits and tickets. ' \
                   'The initial issued email on creation is always sent.',
      enabled: false,
      allow_opt_out: false
    },
    'application_review' => {
      name: 'Application review reminder',
      description: 'Reminds executive reviewers when membership applications are waiting for a decision.',
      enabled: false,
      allow_opt_out: false,
      remind_under_review: false
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

  def self.sync_catalog_attributes!
    CATALOG.each do |key, attrs|
      setting = find_or_initialize_by(key: key)
      setting.assign_attributes(attrs.slice(:name, :description))
      setting.save! if setting.changed?
    end
  end
end
