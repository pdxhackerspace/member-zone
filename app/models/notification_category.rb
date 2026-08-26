# Authoritative catalog of member-facing notification categories and the mailer actions
# each covers. Admin-facing actions are excluded; see Notifications::DeliveryGate.
class NotificationCategory
  CHANNELS = %w[email slack].freeze
  SOURCES = %w[email_link self_service admin].freeze

  Entry = Data.define(:key, :name, :description, :group, :reminder_key, :mailer_actions)

  CATALOG = {
    'payment_overdue' => {
      name: 'Overdue payment reminders',
      description: 'Reminders when your membership dues are past due.',
      group: 'Reminders',
      reminder_key: 'payment_overdue',
      mailer_actions: %w[payment_past_due]
    },
    'orientation' => {
      name: 'Orientation reminders',
      description: 'Reminders to book your building access orientation.',
      group: 'Reminders',
      reminder_key: 'orientation',
      mailer_actions: %w[orientation_reminder]
    },
    'slack_signup' => {
      name: 'Slack signup reminders',
      description: 'Reminders to link your Slack account.',
      group: 'Reminders',
      reminder_key: 'slack_signup',
      mailer_actions: %w[slack_signup_reminder slack_signup_nag]
    },
    'parking_notices' => {
      name: 'Parking permit and ticket reminders',
      description: 'Expiration and follow-up reminders for parking permits and tickets.',
      group: 'Reminders',
      reminder_key: 'parking_notices',
      mailer_actions: %w[
        parking_permit_expiring_soon parking_ticket_expiring_soon
        parking_permit_expired parking_ticket_expired
        parking_permit_overdue_reminder parking_ticket_overdue_reminder
        parking_permit_final_reminder parking_ticket_final_reminder
      ]
    },
    'application_link' => {
      name: 'Application reminders',
      description: 'Reminders and verification emails during the membership application process.',
      group: 'Reminders',
      reminder_key: 'application_link',
      mailer_actions: %w[application_link_reminder application_email_verification]
    },
    'parking_issued' => {
      name: 'Parking notices issued',
      description: 'Confirmation when a parking permit or ticket is created for you.',
      group: 'Parking',
      reminder_key: nil,
      mailer_actions: %w[parking_permit_issued parking_ticket_issued]
    },
    'membership_status' => {
      name: 'Membership status updates',
      description: 'Changes to your membership standing, including cancellation, lapse, and sponsorship.',
      group: 'Membership',
      reminder_key: nil,
      mailer_actions: %w[membership_cancelled membership_banned membership_lapsed membership_sponsored]
    },
    'application_outcome' => {
      name: 'Application updates',
      description: 'Receipt and outcome emails for your membership application.',
      group: 'Membership',
      reminder_key: nil,
      mailer_actions: %w[application_received application_approved application_rejected]
    },
    'training' => {
      name: 'Training records',
      description: 'When you are marked trained or granted trainer capability.',
      group: 'Training',
      reminder_key: nil,
      mailer_actions: %w[training_completed trainer_capability_granted]
    },
    'training_requests' => {
      name: 'Training requests',
      description: 'When someone requests training from you or about you.',
      group: 'Training',
      reminder_key: nil,
      mailer_actions: %w[training_requested]
    },
    'messages' => {
      name: 'Direct messages',
      description: 'Messages sent to you through Member Zone.',
      group: 'Messages',
      reminder_key: nil,
      mailer_actions: %w[message_received]
    },
    'account_security' => {
      name: 'Account security',
      description: 'Login links and related account access emails.',
      group: 'Account',
      reminder_key: nil,
      mailer_actions: %w[login_link_sent login_link_expired]
    }
  }.freeze

  ADMIN_MAILER_ACTIONS = MailRecipientGuard::ADMIN_MAILER_ACTIONS.freeze

  class << self
    def all
      @all ||= CATALOG.map { |key, attrs| build_entry(key, attrs) }
    end

    def find(key)
      attrs = CATALOG[key.to_s]
      attrs ? build_entry(key.to_s, attrs) : nil
    end

    def for_mailer_action(action)
      action = action.to_s
      return nil if ADMIN_MAILER_ACTIONS.include?(action)

      @mailer_action_index ||= build_mailer_action_index
      key = @mailer_action_index[action]
      key ? find(key) : nil
    end

    def grouped_for_member
      all.group_by(&:group)
    end

    def reminder_backed
      all.select(&:reminder_key)
    end

    def opt_out_allowed?(category_key)
      entry = find(category_key)
      return false unless entry&.reminder_key

      ReminderSetting.find_by(key: entry.reminder_key)&.allow_opt_out? == true
    end

    def member_mailer_actions
      CATALOG.values.flat_map { |attrs| attrs[:mailer_actions] }
    end

    private

    def build_entry(key, attrs)
      Entry.new(
        key: key,
        name: attrs[:name],
        description: attrs[:description],
        group: attrs[:group],
        reminder_key: attrs[:reminder_key],
        mailer_actions: attrs[:mailer_actions].freeze
      )
    end

    def build_mailer_action_index
      CATALOG.each_with_object({}) do |(key, attrs), index|
        attrs[:mailer_actions].each { |action| index[action] = key }
      end
    end
  end
end
