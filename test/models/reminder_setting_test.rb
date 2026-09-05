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
end
