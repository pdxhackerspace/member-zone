# Prevents outbound mail to members in terminal states (banned or deceased). Blocked
# deliveries are auto-rejected in the mail queue when possible, and admins are warned.
class MailRecipientGuard
  ADMIN_MAILER_ACTIONS = %w[
    admin_new_application
    staff_new_application
    staff_application_reminder
    staff_application_nag
    admin_dashboard_urgent_digest
    blocked_recipient_delivery_attempt
  ].freeze

  SKIP_MAILER_CLASSES = %w[QueuedMailMailer EmailTemplateMailer].freeze

  MEMBERSHIP_STATE_LABELS = {
    'banned_member' => 'Banned',
    'deceased_member' => 'Deceased'
  }.freeze

  # The ban notification is the one email a banned member may receive, and it waits in the
  # review queue for an admin to edit and approve deliberately.
  BANNED_MEMBER_ALLOWED_ACTIONS = %w[membership_banned].freeze

  class << self
    def blocked?(user)
      user&.terminal_membership_state?
    end

    def allowed_for_terminal_recipient?(queued_mail, recipient)
      recipient&.banned? && BANNED_MEMBER_ALLOWED_ACTIONS.include?(queued_mail.mailer_action.to_s)
    end

    def blocked_email?(email)
      normalized = email.to_s.strip
      return false if normalized.blank?

      blocked?(User.lookup_by_email(normalized))
    end

    def admin_facing_delivery?(mailer_class:, mailer_action:)
      SKIP_MAILER_CLASSES.include?(mailer_class.to_s) ||
        ADMIN_MAILER_ACTIONS.include?(mailer_action.to_s)
    end

    def block_delivery_to!(queued_mail)
      recipient = queued_mail.recipient || User.lookup_by_email(queued_mail.to)
      return false unless blocked?(recipient)
      return false if allowed_for_terminal_recipient?(queued_mail, recipient)
      return true if queued_mail.rejected?

      auto_reject!(queued_mail)
      notify_admins!(queued_mail: queued_mail, recipient: recipient)
      true
    end

    def block_direct_delivery!(to:, subject:, mailer_class:, mailer_action:)
      return false if admin_facing_delivery?(mailer_class: mailer_class, mailer_action: mailer_action)

      blocked_addresses = Array(to).compact.select { |address| blocked_email?(address) }
      return false if blocked_addresses.empty?

      notify_admins!(
        recipient: User.lookup_by_email(blocked_addresses.first),
        subject: subject,
        mailer_action: mailer_action,
        mailer_class: mailer_class,
        delivery_to: blocked_addresses.join(', ')
      )
      true
    end

    def withdraw_pending_mail!(user)
      return unless blocked?(user)

      scope = QueuedMail.where(recipient: user, status: %w[pending approved], sent_at: nil)
      scope = scope.where.not(mailer_action: BANNED_MEMBER_ALLOWED_ACTIONS) if user.banned?
      scope.find_each { |mail| block_delivery_to!(mail) }
    end

    def notify_admins!(details = {})
      details = details.symbolize_keys
      queued_mail = details[:queued_mail]
      recipient = details[:recipient] || queued_mail&.recipient
      subject = details[:subject] || queued_mail&.subject
      mailer_action = details[:mailer_action] || queued_mail&.mailer_action
      delivery_to = details[:delivery_to] || queued_mail&.to

      User.admin.find_each do |admin|
        next if admin.email.to_s.strip.blank?

        MemberMailer.blocked_recipient_delivery_attempt(
          admin,
          recipient: recipient,
          subject: subject,
          mailer_action: mailer_action,
          mailer_class: details[:mailer_class],
          delivery_to: delivery_to,
          queued_mail: queued_mail
        ).deliver_later
      end
    end

    def rejection_details(queued_mail)
      recipient = queued_mail.recipient || User.lookup_by_email(queued_mail.to)
      label = membership_state_label(recipient)
      "Auto-rejected: recipient is #{label.downcase}"
    end

    def blocked_recipient_alert_message(queued_mail)
      recipient = queued_mail.recipient || User.lookup_by_email(queued_mail.to)
      label = membership_state_label(recipient).downcase
      name = recipient&.display_name || queued_mail.to
      "Message not sent: #{name} is #{label}."
    end

    def rejection_details_for_direct(to:, mailer_class:, mailer_action:)
      addresses = Array(to).compact.join(', ')
      "Auto-rejected direct delivery to #{addresses} (#{mailer_class}##{mailer_action})"
    end

    private

    def auto_reject!(queued_mail)
      queued_mail.update!(status: 'rejected', reviewed_by: nil, reviewed_at: Time.current)
      MailLogEntry.log!(queued_mail, 'rejected', details: rejection_details(queued_mail))
    end

    def membership_state_label(user)
      return 'Banned or deceased' if user.blank?

      MEMBERSHIP_STATE_LABELS.fetch(user.membership_state, user.membership_state.humanize)
    end
  end
end
