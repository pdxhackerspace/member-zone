# frozen_string_literal: true

require 'test_helper'

class MemberMailerTest < ActionMailer::TestCase
  class FailingDelivery
    def initialize(_settings = {}); end

    def deliver!(_mail)
      raise 'smtp down'
    end
  end

  test 'admin_new_application includes application URL in body when provided' do
    EmailTemplate.where(key: 'admin_new_application').update_all(enabled: false)

    applicant = users(:one)
    url = 'https://www.example.com/membership_applications/4242'

    email = nil
    assert_difference 'MailLogEntry.count', 1 do
      email = MemberMailer.admin_new_application(applicant, 'ops@example.com', application_url: url).deliver_now
    end

    entry = MailLogEntry.order(:created_at).last
    assert_nil entry.queued_mail_id
    assert_equal 'ops@example.com', entry.delivery_to
    assert entry.delivery_subject.present?
    assert_includes entry.delivery_body_html, url

    assert_includes email.html_part.body.to_s, url
    text = email.text_part ? email.text_part.body.to_s : email.body.to_s
    assert_includes text, url
  end

  test 'training_requested withholds email and slack when contact not shared' do
    EmailTemplate.where(key: 'training_requested').update_all(enabled: false)

    member = users(:one)
    trainer = users(:two)
    email = MemberMailer.training_requested(
      trainer,
      training_topic: 'Laser Cutter',
      requester_name: member.display_name,
      share_contact_info: false,
      recipient_role: 'trainer',
      trainer_names: 'Trainer One'
    ).deliver_now

    html = email.html_part.body.to_s
    text = email.text_part.body.to_s
    assert_includes html, 'withheld'
    assert_not_includes html, member.email
    assert_not_includes html, 'Slack:'
    assert_includes text, 'Email: withheld'
    assert_not_includes text, member.email
  end

  test 'training_requested includes slack handle when contact shared' do
    EmailTemplate.where(key: 'training_requested').update_all(enabled: false)

    member = users(:one)
    member.update!(slack_handle: 'laser-trainee')
    trainer = users(:two)
    email = MemberMailer.training_requested(
      trainer,
      training_topic: 'Laser Cutter',
      requester_name: member.display_name,
      requester_email: member.email,
      requester_slack: 'laser-trainee',
      share_contact_info: true,
      recipient_role: 'trainer',
      trainer_names: 'Trainer One'
    ).deliver_now

    html = email.html_part.body.to_s
    assert_includes html, member.email
    assert_includes html, 'laser-trainee'
  end

  test 'application email verification logs failed delivery instead of sent when delivery raises' do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache.lookup_store(:memory_store)
    Rails.cache.clear
    ActionMailer::Base.add_delivery_method :member_zone_failure, FailingDelivery
    original_delivery_method = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :member_zone_failure

    sent_verification_mail_count = lambda {
      MailLogEntry.where(event: 'sent', delivery_action: 'application_email_verification').count
    }
    failed_verification_mail_count = lambda {
      MailLogEntry.where(event: 'send_failed', delivery_action: 'application_email_verification').count
    }

    assert_no_difference sent_verification_mail_count do
      assert_difference failed_verification_mail_count, 1 do
        assert_raises RuntimeError do
          MemberMailer.application_email_verification(
            'applicant@example.com',
            verification_url: 'https://example.com/verify',
            expires_in: '24 hours'
          ).deliver_now
        end
      end
    end

    entry = MailLogEntry.where(event: 'send_failed', delivery_action: 'application_email_verification').last
    assert_equal 'applicant@example.com', entry.delivery_to
    assert_match(/smtp down/, entry.details)
    assert_includes entry.delivery_body_html, 'https://example.com/verify'
    assert_equal 1, MailerDeliveryMonitor.recent_failures.size
    assert_match(/smtp down/, MailerDeliveryMonitor.recent_failures.last['message'])
  ensure
    Rails.cache = original_cache if defined?(original_cache)
    ActionMailer::Base.delivery_method = original_delivery_method if defined?(original_delivery_method)
  end

  test 'slack signup template omits self-link copy when OIDC is unavailable' do
    template = EmailTemplate.create!(
      key: 'slack_signup_nag_test',
      name: 'Slack Signup Test',
      subject: 'Join Slack',
      body_html: EmailTemplate::DEFAULT_TEMPLATES.fetch('slack_signup_reminder')[:body_html],
      body_text: EmailTemplate::DEFAULT_TEMPLATES.fetch('slack_signup_reminder')[:body_text],
      enabled: true
    )

    original_oidc = Rails.application.config.x.slack_oidc
    Rails.application.config.x.slack_oidc = ActiveSupport::InheritableOptions.new(
      client_id: nil,
      client_secret: nil,
      team_id: nil
    )

    user = users(:one)
    variables = MemberMailer.build_template_variables(user, MemberMailer.slack_signup_template_extras(user))
    rendered = template.render(variables)

    assert_not_includes rendered[:body_html], 'href=""'
    assert_not_includes rendered[:body_html], 'Associate your Slack account'
    assert_includes rendered[:body_html], 'ask an admin for an invite'
    assert_not_includes rendered[:body_text], 'Associate your Slack account:'
  ensure
    Rails.application.config.x.slack_oidc = original_oidc
    template&.destroy
  end

  test 'slack signup template includes self-link copy when OIDC is configured' do
    template = EmailTemplate.create!(
      key: 'slack_signup_nag_test',
      name: 'Slack Signup Test',
      subject: 'Join Slack',
      body_html: EmailTemplate::DEFAULT_TEMPLATES.fetch('slack_signup_reminder')[:body_html],
      body_text: EmailTemplate::DEFAULT_TEMPLATES.fetch('slack_signup_reminder')[:body_text],
      enabled: true
    )

    original_oidc = Rails.application.config.x.slack_oidc
    Rails.application.config.x.slack_oidc = ActiveSupport::InheritableOptions.new(
      client_id: 'client-id',
      client_secret: 'client-secret',
      team_id: 'T123'
    )

    user = users(:one)
    variables = MemberMailer.build_template_variables(user, MemberMailer.slack_signup_template_extras(user))
    rendered = template.render(variables)

    assert_includes rendered[:body_html], 'Associate your Slack account'
    assert_includes rendered[:body_html], '/slack/link'
    assert_includes rendered[:body_text], 'Associate your Slack account:'
  ensure
    Rails.application.config.x.slack_oidc = original_oidc
    template&.destroy
  end

  test 'lapsed_access_reminder renders fallback views when template is disabled' do
    user = lapsed_member_for_fallback_views

    travel_to Time.zone.local(2026, 9, 5, 8, 0, 0) do
      AccessLog.create!(user: user, logged_at: 20.hours.ago, name: user.display_name, action: 'opened')
      email = MemberMailer.lapsed_access_reminder(user).deliver_now

      assert_equal [user.email], email.to
      assert_includes email.subject, 'Your membership has lapsed'
      assert_includes email.html_part.body.to_s, 'facilities yesterday'
      assert_includes email.text_part.body.to_s, 'facilities yesterday'
    end
  end

  # The copy used to say "yesterday" unconditionally, which a visit earlier the same morning and
  # a widened lookback window both contradict.
  test 'lapsed_access_reminder describes the visits rather than assuming yesterday' do
    user = lapsed_member_for_fallback_views

    travel_to Time.zone.local(2026, 9, 5, 8, 0, 0) do
      AccessLog.create!(user: user, logged_at: 2.hours.ago, name: user.display_name, action: 'opened')
      AccessLog.create!(user: user, logged_at: 30.minutes.ago, name: user.display_name, action: 'opened')
      email = MemberMailer.lapsed_access_reminder(user).deliver_now

      assert_includes email.html_part.body.to_s, 'facilities 2 times today'
      assert_includes email.text_part.body.to_s, 'facilities 2 times today'
    end
  end

  private

  # A fresh member rather than a fixture, whose own access logs would be mistaken for the visits
  # under test.
  def lapsed_member_for_fallback_views
    EmailTemplate.where(key: 'lapsed_access_reminder').update_all(enabled: false)
    User.create!(
      email: 'lapsed-fallback@example.com',
      full_name: 'Lapsed Fallback User',
      service_account: false,
      membership_state: 'inactive_member',
      payment_type: 'unknown',
      last_payment_date: 30.days.ago.to_date
    ).tap { |user| user.update_columns(membership_state_entered_at: 45.days.ago) }
  end
end
