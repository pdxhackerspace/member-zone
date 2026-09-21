require 'test_helper'

class NotificationCategoryTest < ActiveSupport::TestCase
  test 'every member mailer action is cataloged or admin-only' do
    member_mailer_actions = MemberMailer.public_instance_methods(false).map(&:to_s).sort
    covered = NotificationCategory.member_mailer_actions +
              NotificationCategory::ADMIN_MAILER_ACTIONS

    missing = member_mailer_actions - covered
    assert_empty missing, "Uncatalogued MemberMailer actions: #{missing.join(', ')}"
  end

  test 'every email template key is cataloged or admin-only' do
    covered = NotificationCategory.member_mailer_actions + NotificationCategory::ADMIN_MAILER_ACTIONS

    missing = EmailTemplate::DEFAULT_TEMPLATES.keys.map(&:to_s) - covered
    assert_empty missing, "Uncatalogued email template keys: #{missing.join(', ')}"
  end

  # Parking is compliance mail a member cannot decline; staff_application goes to reviewers,
  # not to members, so there is nobody holding a preference for it. Everything else is
  # optional by default.
  test 'only parking notices and the staff application reminder disable opt-out by default' do
    ReminderSetting.seed_defaults!
    mandatory = %w[parking_notices staff_application]

    mandatory.each do |key|
      assert_not ReminderSetting.find_by!(key: key).allow_opt_out?, "expected #{key} to disallow opt-out"
    end

    (ReminderSetting::CATALOG.keys - mandatory).each do |key|
      setting = ReminderSetting.find_by!(key: key)
      assert setting.allow_opt_out?, "expected #{key} to allow opt-out"
    end
  end

  test 'opt_out_allowed reflects reminder setting' do
    ReminderSetting.seed_defaults!
    ReminderSetting.find_by!(key: 'payment_overdue').update!(allow_opt_out: true)
    assert NotificationCategory.opt_out_allowed?('payment_overdue')

    ReminderSetting.find_by!(key: 'parking_notices').update!(allow_opt_out: false)
    assert_not NotificationCategory.opt_out_allowed?('parking_notices')
  end

  test 'for_mailer_action resolves reminder and mandatory categories' do
    assert_equal 'payment_overdue', NotificationCategory.for_mailer_action('payment_past_due').key
    assert_equal 'parking_issued', NotificationCategory.for_mailer_action('parking_permit_issued').key
    assert_nil NotificationCategory.for_mailer_action('staff_application_reminder')
  end
end
