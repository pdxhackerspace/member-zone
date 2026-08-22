require 'test_helper'

class MailRecipientGuardTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ActionMailer::Base.deliveries.clear
    @admin = users(:one)
    @admin.update!(is_admin: true)
    @member = users(:three)
  end

  test 'blocked? is true for banned and deceased members' do
    @member.update_columns(membership_state: 'banned_member')
    assert MailRecipientGuard.blocked?(@member.reload)

    @member.update_columns(membership_state: 'deceased_member')
    assert MailRecipientGuard.blocked?(@member.reload)
  end

  test 'blocked? is false for active members' do
    assert_not MailRecipientGuard.blocked?(users(:two))
  end

  test 'enqueue holds membership_banned for a banned member pending review' do
    @member.update_columns(membership_state: 'banned_member', email: 'banned-ban-mail@example.com')

    assert_no_enqueued_jobs only: ActionMailer::MailDeliveryJob do
      record = QueuedMail.enqueue(:membership_banned, @member.reload, reason: 'Member banned')
      assert_predicate record, :pending?
    end

    assert_equal 'membership_banned', QueuedMail.last.mailer_action
    assert_not QueuedMail.last.mail_log_entries.exists?(event: 'rejected')
  end

  test 'approve! allows membership_banned delivery to a banned member' do
    @member.update_columns(membership_state: 'banned_member', email: 'banned-approve-ban@example.com')
    mail = QueuedMail.create!(
      to: @member.email,
      subject: 'Account suspended',
      body_html: '<p>You are banned</p>',
      body_text: 'You are banned',
      reason: 'Member banned',
      mailer_action: 'membership_banned',
      recipient: @member,
      status: 'pending'
    )

    assert_enqueued_jobs 1, only: QueuedMailDeliveryJob do
      assert mail.approve!(users(:one))
    end

    assert_predicate mail.reload, :approved?
  end

  test 'deliver_now! sends membership_banned to a banned member' do
    @member.update_columns(membership_state: 'banned_member', email: 'banned-deliver-ban@example.com')
    mail = QueuedMail.create!(
      to: @member.email,
      subject: 'Account suspended',
      body_html: '<p>You are banned</p>',
      body_text: 'You are banned',
      reason: 'Member banned',
      mailer_action: 'membership_banned',
      recipient: @member,
      status: 'approved',
      reviewed_by: users(:one),
      reviewed_at: Time.current
    )

    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      mail.deliver_now!
    end

    assert_predicate mail.reload, :sent?
  end

  test 'withdraw_pending_mail! leaves membership_banned waiting in the queue' do
    @member.update_columns(membership_state: 'current_member', email: 'withdraw-ban@example.com')
    ban_mail = QueuedMail.create!(
      to: @member.email,
      subject: 'Account suspended',
      body_html: '<p>You are banned</p>',
      body_text: 'You are banned',
      reason: 'Member banned',
      mailer_action: 'membership_banned',
      recipient: @member,
      status: 'pending'
    )
    reminder = QueuedMail.create!(
      to: @member.email,
      subject: 'Reminder',
      body_html: '<p>Hi</p>',
      body_text: 'Hi',
      reason: 'Test',
      mailer_action: 'payment_past_due',
      recipient: @member,
      status: 'pending'
    )

    @member.update_columns(membership_state: 'banned_member')
    MailRecipientGuard.withdraw_pending_mail!(@member.reload)

    assert_predicate ban_mail.reload, :pending?
    assert_predicate reminder.reload, :rejected?
  end

  test 'notify_membership_banned skips enqueue when ban mail is already queued' do
    @member.update_columns(membership_state: 'current_member', email: 'ban-dedupe@example.com')
    QueuedMail.create!(
      to: @member.email,
      subject: 'Account suspended',
      body_html: '<p>You are banned</p>',
      body_text: 'You are banned',
      reason: 'Member banned',
      mailer_action: 'membership_banned',
      recipient: @member,
      status: 'pending'
    )

    @member.update_columns(membership_state: 'banned_member')
    Current.skip_membership_state_email = false
    @member.send(:notify_membership_banned)

    assert_equal 1, QueuedMail.where(recipient: @member, mailer_action: 'membership_banned').count
  end

  test 'enqueue auto-rejects mail to a banned member and warns admins' do
    @member.update_columns(membership_state: 'banned_member', email: 'banned-mail@example.com')

    assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
      record = QueuedMail.enqueue(:payment_past_due, @member.reload, reason: 'Payment past due')
      assert_predicate record, :rejected?
    end

    assert_equal 'payment_past_due', QueuedMail.last.mailer_action
    assert_match 'banned', QueuedMail.last.mail_log_entries.where(event: 'rejected').last.details
  end

  test 'approve! refuses delivery to a deceased member' do
    @member.update_columns(membership_state: 'deceased_member', email: 'deceased-mail@example.com')
    mail = QueuedMail.create!(
      to: @member.email,
      subject: 'Reminder',
      body_html: '<p>Hi</p>',
      body_text: 'Hi',
      reason: 'Test',
      mailer_action: 'payment_past_due',
      recipient: @member,
      status: 'pending'
    )

    assert_no_enqueued_jobs only: QueuedMailDeliveryJob do
      assert_not mail.approve!(users(:one))
    end

    assert_predicate mail.reload, :rejected?
  end

  test 'deliver_now! blocks approved mail when recipient becomes banned' do
    @member.update_columns(membership_state: 'banned_member', email: 'banned-deliver@example.com')
    mail = QueuedMail.create!(
      to: @member.email,
      subject: 'Reminder',
      body_html: '<p>Hi</p>',
      body_text: 'Hi',
      reason: 'Test',
      mailer_action: 'payment_past_due',
      recipient: @member,
      status: 'approved',
      reviewed_by: users(:one),
      reviewed_at: Time.current
    )

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      mail.deliver_now!
    end

    assert_predicate mail.reload, :rejected?
    assert_nil mail.sent_at
  end

  test 'withdraw_pending_mail! rejects waiting queue entries when member is banned' do
    @member.update_columns(membership_state: 'current_member', email: 'withdraw@example.com')
    pending = QueuedMail.create!(
      to: @member.email,
      subject: 'Reminder',
      body_html: '<p>Hi</p>',
      body_text: 'Hi',
      reason: 'Test',
      mailer_action: 'payment_past_due',
      recipient: @member,
      status: 'pending'
    )
    approved = QueuedMail.create!(
      to: @member.email,
      subject: 'Other',
      body_html: '<p>Hi</p>',
      body_text: 'Hi',
      reason: 'Test',
      mailer_action: 'orientation_reminder',
      recipient: @member,
      status: 'approved'
    )

    @member.update_columns(membership_state: 'banned_member')
    MailRecipientGuard.withdraw_pending_mail!(@member.reload)

    assert_predicate pending.reload, :rejected?
    assert_predicate approved.reload, :rejected?
  end

  test 'block_direct_delivery! stops direct member mailer delivery' do
    @member.update_columns(membership_state: 'banned_member', email: 'banned-direct@example.com')
    message = MemberMailer.message_received(
      Message.new(
        sender: users(:two),
        recipient: @member,
        subject: 'Hello',
        body: 'Test'
      )
    )

    blocked = MailRecipientGuard.block_direct_delivery!(
      to: message.to,
      subject: message.subject,
      mailer_class: 'MemberMailer',
      mailer_action: 'message_received'
    )

    assert blocked
    assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob
  end

  test 'block_direct_delivery! allows admin-facing mail' do
    assert_not MailRecipientGuard.block_direct_delivery!(
      to: 'ops@example.com',
      subject: 'New application',
      mailer_class: 'MemberMailer',
      mailer_action: 'admin_new_application'
    )
  end

  test 'blocked_recipient_alert_message works without a linked recipient' do
    @member.update_columns(membership_state: 'banned_member', email: 'banned@example.com')
    mail = QueuedMail.create!(
      to: 'banned@example.com',
      subject: 'Invitation',
      body_html: '<p>Hi</p>',
      body_text: 'Hi',
      reason: 'Invitation',
      mailer_action: 'invitation',
      recipient: nil,
      status: 'pending'
    )
    MailRecipientGuard.block_delivery_to!(mail)

    message = MailRecipientGuard.blocked_recipient_alert_message(mail.reload)
    assert_includes message, 'banned@example.com'
    assert_includes message.downcase, 'banned'
  end
end
