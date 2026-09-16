class ReminderSetting < ApplicationRecord
  CATALOG = {
    'slack_signup' => {
      name: 'Slack signup reminder',
      description: 'Gentle reminder to active members without a linked Slack account.',
      enabled: false,
      allow_opt_out: true,
      email_template_keys: %w[slack_signup_reminder]
    },
    'application_link' => {
      name: 'Application link reminder',
      description: 'Reminder when someone requested a membership application link but has not submitted yet.',
      enabled: false,
      allow_opt_out: true,
      email_template_keys: %w[application_link_reminder]
    },
    'payment_overdue' => {
      name: 'Overdue payment reminder',
      description: 'Weekly reminder to members whose dues are past due, and the one-off notice when their overdue ' \
                   'grace period runs out and they lapse. Members who have cancelled are not reminded. The lapse ' \
                   'notice is a membership status email and sends whether or not this reminder is enabled.',
      enabled: false,
      allow_opt_out: true,
      # The lapse notice is not sent by the reminder job — Membership::TickJob walks the
      # member into inactive_member and the state-entry email follows. It is named here so
      # that the whole sequence an overdue member sees is in one place, which is the only
      # place an admin goes looking for it.
      email_template_keys: %w[payment_past_due membership_lapsed]
    },
    'orientation' => {
      name: 'Orientation reminder',
      description: 'Reminder to approved members who have not had their building access orientation yet.',
      enabled: false,
      allow_opt_out: true,
      email_template_keys: %w[orientation_reminder]
    },
    'parking_notices' => {
      name: 'Parking notice reminders',
      description: 'Pre-expiration, expiration, and follow-up reminders for parking permits and tickets. ' \
                   'The initial issued email on creation is always sent.',
      enabled: false,
      allow_opt_out: false,
      email_template_keys: %w[
        parking_permit_expiring_soon parking_ticket_expiring_soon
        parking_permit_expired parking_ticket_expired
        parking_permit_overdue_reminder parking_ticket_overdue_reminder
        parking_permit_final_reminder parking_ticket_final_reminder
      ]
    },
    'lapsed_access' => {
      name: 'Lapsed member access reminder',
      description: 'Daily reminder to inactive members who badged in recently that their membership has lapsed ' \
                   'and how to reactivate. Each visit is only ever mentioned once.',
      enabled: false,
      allow_opt_out: true,
      lookback_days: 1,
      configurable_lookback: true,
      email_template_keys: %w[lapsed_access_reminder]
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

  # Nothing joins a reminder to its templates in the database — QueuedMail resolves a template
  # from the mailer action at send time — so the catalog names the keys a reminder can send.
  def email_template_keys
    CATALOG.dig(key, :email_template_keys) || []
  end

  def email_templates
    self.class.templates_for_keys(email_template_keys)
  end

  # Every reminder's templates in one query, for pages that list the whole catalog.
  def self.email_templates_by_reminder_key
    found = EmailTemplate.where(key: catalog_email_template_keys).index_by(&:key)
    CATALOG.transform_values do |attrs|
      attrs.fetch(:email_template_keys, []).filter_map { |key| found[key] }
    end
  end

  def self.catalog_email_template_keys
    CATALOG.values.flat_map { |attrs| attrs.fetch(:email_template_keys, []) }
  end

  # Catalog order is the order the reminder sends them in, which the database cannot express.
  def self.templates_for_keys(keys)
    return [] if keys.empty?

    found = EmailTemplate.where(key: keys).index_by(&:key)
    keys.filter_map { |key| found[key] }
  end

  def self.sync_catalog_attributes!
    CATALOG.each do |key, attrs|
      setting = find_or_initialize_by(key: key)
      setting.assign_attributes(attrs.slice(:name, :description))
      setting.save! if setting.changed?
    end
  end
end
