require 'test_helper'

class ReminderSettingTest < ActiveSupport::TestCase
  setup do
    ReminderSetting.seed_defaults!
  end

  test 'seed_defaults ignores catalog keys that have no column' do
    ReminderSetting.where(key: 'lapsed_access').delete_all

    assert_nothing_raised { ReminderSetting.seed_defaults! }

    setting = ReminderSetting.find_by!(key: 'lapsed_access')
    assert_equal 1, setting.lookback_days
    assert_not_respond_to setting, :configurable_lookback
  end

  test 'only reminders that scan a time range expose a lookback window' do
    assert_predicate ReminderSetting.find_by!(key: 'lapsed_access'), :configurable_lookback?
    assert_not_predicate ReminderSetting.find_by!(key: 'payment_overdue'), :configurable_lookback?
  end

  test 'lookback_days must be a whole number of days within range' do
    setting = ReminderSetting.find_by!(key: 'lapsed_access')

    assert setting.update(lookback_days: 30)

    assert_not setting.update(lookback_days: 0)
    assert_not setting.update(lookback_days: ReminderSetting::MAX_LOOKBACK_DAYS + 1)
    assert_not setting.update(lookback_days: nil)
    assert_equal 30, setting.reload.lookback_days
  end

  test 'lookback_days_for reads the stored window and nil for unknown reminders' do
    ReminderSetting.find_by!(key: 'lapsed_access').update!(lookback_days: 5)

    assert_equal 5, ReminderSetting.lookback_days_for('lapsed_access')
    assert_nil ReminderSetting.lookback_days_for('not_a_reminder')
  end

  test 'every reminder names at least one email template it can send' do
    ReminderSetting.ordered.each do |reminder|
      assert_not_empty reminder.email_template_keys, "#{reminder.key} names no email template"
    end
  end

  test 'parking notice reminders cover both permits and tickets in every phase' do
    keys = ReminderSetting.find_by!(key: 'parking_notices').email_template_keys

    assert_equal 8, keys.size
    %w[expiring_soon expired overdue_reminder final_reminder].each do |phase|
      assert_includes keys, "parking_permit_#{phase}"
      assert_includes keys, "parking_ticket_#{phase}"
    end
  end

  test 'email_template_keys is empty for a reminder outside the catalog' do
    setting = ReminderSetting.new(key: 'not_a_reminder', name: 'Not a reminder')

    assert_empty setting.email_template_keys
    assert_empty setting.email_templates
  end

  test 'email_templates returns the records for the named keys in catalog order' do
    create_template('parking_ticket_expiring_soon')
    permit = create_template('parking_permit_expiring_soon')

    templates = ReminderSetting.find_by!(key: 'parking_notices').email_templates

    assert_equal %w[parking_permit_expiring_soon parking_ticket_expiring_soon], templates.map(&:key)
    assert_equal permit, templates.first
  end

  test 'email_templates skips keys that have no template record' do
    create_template('parking_permit_final_reminder')

    templates = ReminderSetting.find_by!(key: 'parking_notices').email_templates

    assert_equal %w[parking_permit_final_reminder], templates.map(&:key)
  end

  test 'email_templates_by_reminder_key covers every reminder without a query per reminder' do
    create_template('lapsed_access_reminder')
    create_template('payment_past_due')

    by_key = ReminderSetting.email_templates_by_reminder_key

    assert_equal ReminderSetting::CATALOG.keys.sort, by_key.keys.sort
    assert_equal %w[lapsed_access_reminder], by_key['lapsed_access'].map(&:key)
    assert_equal %w[payment_past_due], by_key['payment_overdue'].map(&:key)
    assert_empty by_key['orientation']
  end

  private

  def create_template(key)
    EmailTemplate.create!(
      key: key,
      name: key.titleize,
      subject: "Subject for #{key}",
      body_html: '<p>Body</p>',
      body_text: 'Body',
      enabled: true
    )
  end
end
