# Mail sent when a member's standing changes. Everything here goes through QueuedMail,
# which holds messages for admin review before delivery unless the template opts out.
#
# Cancellation and ban mail is sent once per entry into the state and stamped, so a
# repeated webhook or a second ban does not mail the member again.
module MembershipNotifications
  extend ActiveSupport::Concern

  def notify_membership_state_entered
    return unless saved_change_to_membership_state?
    return if email.blank?

    case membership_state
    when 'cancelled_member' then notify_membership_cancelled
    when 'banned_member' then notify_membership_banned
    when 'inactive_member' then notify_membership_lapsed
    when 'current_member' then clear_membership_cancelled_stamp
    end
  end

  private

  # "Sorry to see you go" — sent when we learn of a cancellation, while the member still
  # has access. Resubscribing within the reactivation window puts them straight back.
  def notify_membership_cancelled
    return if membership_cancelled_email_sent_at.present?

    QueuedMail.enqueue(:membership_cancelled, self, reason: "Membership cancelled for #{display_name}")
    update_column(:membership_cancelled_email_sent_at, Time.current)
  end

  def notify_membership_banned
    QueuedMail.enqueue(:membership_banned, self, reason: "Member banned: #{display_name}")
  end

  def notify_membership_lapsed
    QueuedMail.enqueue(:membership_lapsed, self, reason: "Membership lapsed for #{display_name}")
  end

  # A member who resubscribes and later cancels again should hear from us again.
  def clear_membership_cancelled_stamp
    return if membership_cancelled_email_sent_at.blank?

    update_column(:membership_cancelled_email_sent_at, nil)
  end
end
