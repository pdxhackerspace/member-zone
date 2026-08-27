require 'test_helper'

class MemberMailerNotificationFooterTest < ActionMailer::TestCase
  setup do
    @user = users(:member_with_local_account)
    ReminderSetting.seed_defaults!
  end

  test 'payment_past_due includes opt-out footer in html and text' do
    EmailTemplate.where(key: 'payment_past_due').delete_all
    mail = MemberMailer.payment_past_due(@user, days_overdue: 7)

    assert_includes mail.html_part.body.decoded, 'notification settings'
    assert_includes mail.text_part.body.decoded, 'Manage overdue payment reminders'
  end

  test 'parking_permit_issued includes mandatory footer' do
    EmailTemplate.where(key: 'parking_permit_issued').delete_all
    mail = MemberMailer.parking_permit_issued(
      @user,
      location: 'Lot A',
      location_detail: '',
      description: 'Test',
      expires_at: 1.week.from_now.to_fs(:long),
      notice_type: 'permit'
    )

    html = mail.html_part&.body&.decoded || mail.body.decoded
    assert_includes html, 'required notice'
    text = mail.text_part&.body&.decoded
    assert_includes text, 'required notice' if text.present?
  end

  test 'application_link_reminder fallback renders for applicant recipient' do
    EmailTemplate.where(key: 'application_link_reminder').delete_all
    recipient = QueuedMail::ApplicantMailRecipient.new(
      display_name: 'Applicant',
      email: 'applicant-mailer@example.com',
      username: 'Not set'
    )

    mail = MemberMailer.application_link_reminder(recipient, application_url: 'https://example.com/apply')

    assert_equal [recipient.email], mail.to
    assert_includes mail.subject, 'Complete your membership application'
  end

  test 'application_rejected fallback renders for applicant recipient' do
    EmailTemplate.where(key: 'application_rejected').delete_all
    recipient = QueuedMail::ApplicantMailRecipient.new(
      display_name: 'Applicant',
      email: 'rejected-mailer@example.com',
      username: 'Not set'
    )

    mail = MemberMailer.application_rejected(recipient, reason: 'Not a fit at this time')

    assert_equal [recipient.email], mail.to
    assert_includes mail.subject, 'Update on Your Membership Application'
  end
end
