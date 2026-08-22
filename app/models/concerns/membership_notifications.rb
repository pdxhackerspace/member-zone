# Mail sent when a member's standing changes. Everything here goes through QueuedMail,
# which holds messages for admin review before delivery unless the template opts out.
#
# Cancellation and ban mail is sent once per entry into the state and stamped, so a
# repeated webhook or a second ban does not mail the member again.
module MembershipNotifications
  extend ActiveSupport::Concern

  def notify_membership_state_entered
    return unless saved_change_to_membership_state?

    # Bookkeeping, not mail: a member who is back stops being a member who left, whether or
    # not we are sending anything about it. A payment is the usual way back, but not the only
    # one — someone who lapsed and later reapplied is a member again from the moment their
    # application is approved, before any money arrives.
    clear_cancellation_record if membership_state.in?(MembershipState::REJOINED_STATES)

    return if email.blank?
    return if Current.skip_membership_state_email

    case membership_state
    when 'cancelled_member' then notify_membership_cancelled
    when 'banned_member'
      MailRecipientGuard.withdraw_pending_mail!(self)
      notify_membership_banned
    when 'deceased_member'
      MailRecipientGuard.withdraw_pending_mail!(self)
    when 'inactive_member' then notify_membership_lapsed
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
    return if QueuedMail.pending_ban_mail_for?(self)

    QueuedMail.enqueue(:membership_banned, self, reason: "Member banned: #{display_name}")
  end

  # "Your membership has lapsed" is for someone who drifted off without saying anything. A
  # member who cancelled reached the same state on purpose, was told at the time that their
  # access ran to their paid-through date, and does not need chasing about the date arriving.
  def notify_membership_lapsed
    return if cancellation_on_file?

    QueuedMail.enqueue(:membership_lapsed, self, reason: "Membership lapsed for #{display_name}")
  end

  # A member who rejoins is no longer someone who left: forget the cancellation, so a later
  # lapse reads as a lapse and a second cancellation mails them again.
  def clear_cancellation_record
    stamps = { membership_cancelled_at: nil, membership_cancelled_email_sent_at: nil }
    stamps = stamps.reject { |column, _| self[column].nil? }
    return if stamps.empty?

    update_columns(stamps)
  end
end
