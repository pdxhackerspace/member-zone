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
    'lapsed_access' => {
      name: 'Lapsed member access reminder',
      description: 'Daily reminder to inactive members who badged in recently that their membership has lapsed ' \
                   'and how to reactivate. Each visit is only ever mentioned once.',
      enabled: false,
      allow_opt_out: true,
      lookback_days: 1,
      configurable_lookback: true
    }
  }.freeze

  MAX_LOOKBACK_DAYS = 90

  validates :key, presence: true, uniqueness: true
  validates :name, presence: true
  validates :lookback_days,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_LOOKBACK_DAYS }

  scope :ordered, -> { order(:name) }

  def self.enabled?(key)
    find_by(key: key)&.enabled? == true
  end

  def self.lookback_days_for(key)
    find_by(key: key)&.lookback_days
  end

  def self.seed_defaults!
    CATALOG.each do |key, attrs|
      find_or_create_by!(key: key) do |setting|
        setting.assign_attributes(persistable_attributes(attrs))
      end
    end
  end

  # The catalog also describes behaviour that has no column of its own, such as whether the
  # lookback window is editable, so only real columns can be handed to the record.
  def self.persistable_attributes(attrs)
    attrs.slice(*column_names.map(&:to_sym))
  end

  # Only reminders that scan a time range have a meaningful lookback window to edit.
  def configurable_lookback?
    CATALOG.dig(key, :configurable_lookback) == true
  end

  def self.sync_catalog_attributes!
    CATALOG.each do |key, attrs|
      setting = find_or_initialize_by(key: key)
      setting.assign_attributes(attrs.slice(:name, :description))
      setting.save! if setting.changed?
    end
  end
end
