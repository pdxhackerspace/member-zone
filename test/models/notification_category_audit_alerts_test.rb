require 'test_helper'

class NotificationCategoryAuditAlertsTest < ActiveSupport::TestCase
  test 'audit log alerts are a catalogued category that can be opted out of' do
    entry = NotificationCategory.find('audit_log_alerts')

    assert_equal %w[audit_log_alert], entry.mailer_actions
    assert_nil entry.reminder_key
    assert NotificationCategory.opt_out_allowed?('audit_log_alerts')
  end

  test 'the alert email is routed to that category and is not admin-only' do
    assert_equal 'audit_log_alerts', NotificationCategory.for_mailer_action('audit_log_alert').key
    assert_not_includes NotificationCategory::ADMIN_MAILER_ACTIONS, 'audit_log_alert'
  end

  test 'other non-reminder categories stay mandatory' do
    assert_not NotificationCategory.opt_out_allowed?('account_security')
    assert_not NotificationCategory.opt_out_allowed?('membership_status')
  end

  test 'only people who could receive alerts are shown the category' do
    assert_not_includes visible_keys(users(:two)), 'audit_log_alerts'
    assert_not_includes visible_keys(nil), 'audit_log_alerts'

    holder = users(:one)
    grant_privileges(holder, 'audit_logs.alerts_all')
    assert_includes visible_keys(holder), 'audit_log_alerts'

    topic_holder = users(:three)
    grant_privileges(topic_holder, 'audit_logs.alerts')
    assert_includes visible_keys(topic_holder), 'audit_log_alerts'

    admin = users(:cash_payer)
    admin.update_columns(is_admin: true)
    assert_includes visible_keys(admin), 'audit_log_alerts'
  end

  test 'the delivery gate blocks the alert for an opted-out user only' do
    opted_out = users(:one)
    other = users(:two)
    NotificationOptOut.opt_out!(opted_out, category: 'audit_log_alerts')

    assert Notifications::DeliveryGate.blocked?(mailer_action: 'audit_log_alert', user: opted_out)
    assert_not Notifications::DeliveryGate.blocked?(mailer_action: 'audit_log_alert', user: other)
  end

  test 'opting out of one category does not block another' do
    user = users(:one)
    NotificationOptOut.opt_out!(user, category: 'audit_log_alerts')

    assert_not Notifications::DeliveryGate.blocked?(mailer_action: 'message_received', user: user)
  end

  test 'the email footer offers the opt-out rather than calling the notice required' do
    footer = Notifications::DeliveryGate.footer_for(mailer_action: 'audit_log_alert', user: users(:one),
                                                    email: users(:one).email)

    assert_predicate footer, :opt_out_allowed?
    assert_not_predicate footer, :mandatory?
  end

  private

  def visible_keys(user)
    NotificationCategory.grouped_for_member(user).values.flatten.map(&:key)
  end
end
