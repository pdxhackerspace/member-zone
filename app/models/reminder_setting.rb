class ReminderSetting < ApplicationRecord
  # Every reminder's cadence is the same three numbers: how long after its anchor the first
  # one goes out (negative to send before the anchor), how long between the ones after that,
  # and how many to send in total. A nil max_reminders repeats for as long as the subject
  # stays eligible. Reminders::Schedule turns them into dates; the anchor each reminder counts
  # from lives with its eligibility service.
  CATALOG = {
    'slack_signup' => {
      name: 'Slack signup reminder',
      description: 'Gentle reminder to active members without a linked Slack account.',
      enabled: false,
      allow_opt_out: true,
      anchor_description: 'approval',
      start_offset_days: 7,
      interval_days: 14,
      max_reminders: nil,
      # slack_signup_nag is the name this reminder used to send under. Mail queued before the
      # rename is still out there, so both names count as this reminder's.
      reminder_mailer_actions: %w[slack_signup_reminder slack_signup_nag],
      email_template_keys: %w[slack_signup_reminder]
    },
    'application_link' => {
      name: 'Application link reminder',
      description: 'Reminder when someone requested a membership application link but has not submitted yet.',
      enabled: false,
      allow_opt_out: true,
      anchor_description: 'the link request',
      start_offset_days: 3,
      interval_days: 3,
      max_reminders: 3,
      reminder_mailer_actions: %w[application_link_reminder],
      email_template_keys: %w[application_link_reminder]
    },
    'payment_overdue' => {
      name: 'Overdue payment reminder',
      description: 'Weekly reminder to members whose dues are past due, and the one-off notice when their overdue ' \
                   'grace period runs out and they lapse. Members who have cancelled are not reminded. The lapse ' \
                   'notice is a membership status email and sends whether or not this reminder is enabled.',
      enabled: false,
      allow_opt_out: true,
      anchor_description: 'the dues date',
      start_offset_days: 5,
      interval_days: 7,
      max_reminders: nil,
      # Only payment_past_due is a reminder. membership_lapsed is listed below because admins
      # look for it here, but it fires on a state change and is not part of the cadence.
      reminder_mailer_actions: %w[payment_past_due],
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
      anchor_description: 'approval',
      start_offset_days: 14,
      interval_days: 14,
      max_reminders: nil,
      reminder_mailer_actions: %w[orientation_reminder],
      email_template_keys: %w[orientation_reminder]
    },
    'parking_notices' => {
      name: 'Parking notice reminders',
      description: 'Pre-expiration, expiration, and follow-up reminders for parking permits and tickets. ' \
                   'The initial issued email on creation is always sent.',
      enabled: false,
      allow_opt_out: false,
      anchor_description: 'expiration',
      start_offset_days: -3,
      interval_days: 7,
      # Parking picks its template from where a send falls in the sequence, so the last one is
      # the final notice. Without a maximum there is no last one and the final notice never
      # sends — this reminder is the one that needs a limit set.
      max_reminders: 4,
      reminder_mailer_actions: %w[
        parking_permit_expiring_soon parking_ticket_expiring_soon
        parking_permit_expired parking_ticket_expired
        parking_permit_overdue_reminder parking_ticket_overdue_reminder
        parking_permit_final_reminder parking_ticket_final_reminder
      ],
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
      anchor_description: 'the first visit we have not mentioned',
      start_offset_days: 0,
      interval_days: 1,
      max_reminders: nil,
      reminder_mailer_actions: %w[lapsed_access_reminder],
      email_template_keys: %w[lapsed_access_reminder]
    },
    'staff_application' => {
      name: 'Stale application reminder',
      description: 'Reminder to directors that a membership application has been waiting for review. ' \
                   'Sent to reviewers rather than to the applicant.',
      # The one reminder that ships switched on: a review queue nobody is told about is the
      # problem it exists to prevent.
      enabled: true,
      allow_opt_out: false,
      anchor_description: 'submission',
      start_offset_days: 7,
      interval_days: 3,
      max_reminders: nil,
      # Sent straight to reviewers rather than through the mail queue, so nothing traces a
      # queued mail back to this reminder; the job records its own sends.
      reminder_mailer_actions: [],
      email_template_keys: %w[staff_application_reminder]
    }
  }.freeze

  MAX_LOOKBACK_DAYS = 90
  MAX_START_OFFSET_DAYS = 365
  MAX_INTERVAL_DAYS = 365
  MAX_REMINDER_COUNT = 100

  validates :key, presence: true, uniqueness: true
  validates :name, presence: true
  validates :lookback_days,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_LOOKBACK_DAYS }
  validates :start_offset_days,
            numericality: { only_integer: true, greater_than_or_equal_to: -MAX_START_OFFSET_DAYS,
                            less_than_or_equal_to: MAX_START_OFFSET_DAYS }
  validates :interval_days,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_INTERVAL_DAYS }
  validates :max_reminders,
            numericality: { only_integer: true, greater_than_or_equal_to: 1,
                            less_than_or_equal_to: MAX_REMINDER_COUNT },
            allow_nil: true

  scope :ordered, -> { order(:name) }

  # The reminder's settings, whether or not anybody has saved any. Rows are only created when
  # an admin first opens the Reminders page, so on a fresh install every reminder would
  # otherwise read as missing — and the one reminder that ships enabled would quietly not run.
  # The unsaved stand-in carries exactly the values seeding would have written.
  def self.for_key(key)
    key = key.to_s
    find_by(key: key) || catalog_default(key)
  end

  def self.catalog_default(key)
    attrs = CATALOG[key]
    attrs && new(persistable_attributes(attrs).merge(key: key))
  end

  def self.enabled?(key)
    for_key(key)&.enabled? == true
  end

  def self.lookback_days_for(key)
    for_key(key)&.lookback_days
  end

  def schedule
    Reminders::Schedule.new(self)
  end

  def unlimited_reminders?
    max_reminders.blank?
  end

  # What the reminder counts its offset from, in the words the admin page uses.
  def anchor_description
    CATALOG.dig(key, :anchor_description) || 'the start'
  end

  # The mailer actions that are this reminder's own sends, which is narrower than the
  # templates it is catalogued alongside: payment_overdue lists the lapse notice so admins
  # find it in one place, but that notice fires on a state change and is not a reminder.
  def self.reminder_mailer_actions(key)
    CATALOG.dig(key, :reminder_mailer_actions) || []
  end

  def self.key_for_mailer_action(action)
    action = action.to_s
    @mailer_action_index ||= CATALOG.each_with_object({}) do |(key, attrs), index|
      attrs.fetch(:reminder_mailer_actions, []).each { |mailer_action| index[mailer_action] = key }
    end
    @mailer_action_index[action]
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

  # Opting out is a member's choice about their own mail, so it only means anything for a
  # reminder a member receives. staff_application goes to reviewers and has no notification
  # category pointing at it, which is what makes the switch meaningless there.
  def member_facing?
    NotificationCategory.reminder_backed.any? { |entry| entry.reminder_key == key }
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
