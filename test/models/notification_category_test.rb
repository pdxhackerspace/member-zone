require 'test_helper'

class NotificationCategoryTest < ActiveSupport::TestCase
  test 'every member mailer action is cataloged or admin-only' do
    member_mailer_actions = MemberMailer.public_instance_methods(false).map(&:to_s).sort
    covered = NotificationCategory.member_mailer_actions +
              NotificationCategory::ADMIN_MAILER_ACTIONS

    missing = member_mailer_actions - covered
    assert_empty missing, "Uncatalogued MemberMailer actions: #{missing.join(', ')}"
  end

  test 'parking notices is the only reminder with opt-out disabled by default' do
    ReminderSetting.seed_defaults!
    parking = ReminderSetting.find_by!(key: 'parking_notices')
    assert_not parking.allow_opt_out?

    (ReminderSetting::CATALOG.keys - ['parking_notices']).each do |key|
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
