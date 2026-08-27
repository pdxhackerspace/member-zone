require 'test_helper'

class EmailTemplateMailerTest < ActionMailer::TestCase
  setup do
    @user = users(:member_with_local_account)
    ReminderSetting.seed_defaults!
    ActionMailer::Base.deliveries.clear
  end

  test 'send_rendered includes notification footer for member template action' do
    mail = EmailTemplateMailer.send_rendered(member_rendered_mail)

    assert_includes mail.text_part.body.decoded, 'Manage overdue payment reminders'
    assert_match %r{/notifications/[^?\s]+}, mail.text_part.body.decoded
  end

  test 'send_rendered includes applicant opt-out footer for application link reminder' do
    mail = EmailTemplateMailer.send_rendered(applicant_rendered_mail)

    assert_includes mail.text_part.body.decoded, '/apply/notifications/applicant-verification-token'
  end

  test 'send_rendered suppresses delivery when member opted out' do
    NotificationOptOut.opt_out!(@user, category: 'payment_overdue', channel: 'email')

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      EmailTemplateMailer.send_rendered(member_rendered_mail).deliver_now
    end
  end

  private

  def member_rendered_mail
    EmailTemplateMailer::RenderedMail.new(
      to: @user.email,
      subject: 'Payment due',
      body_html: '<p>Template body</p>',
      body_text: 'Template body',
      mailer_action: 'payment_past_due',
      user: @user,
      verification_token: nil
    )
  end

  def applicant_rendered_mail
    EmailTemplateMailer::RenderedMail.new(
      to: 'applicant-immediate@example.com',
      subject: 'Complete your application',
      body_html: '<p>Apply now</p>',
      body_text: 'Apply now',
      mailer_action: 'application_link_reminder',
      user: nil,
      verification_token: 'applicant-verification-token'
    )
  end
end
