require 'test_helper'

class ReminderDeliveryTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.local(2026, 9, 1, 7, 0, 0)
    @anchor = @now - 10.days
    @user = User.create!(email: 'delivery@example.com', full_name: 'Delivery Subject',
                         service_account: false, membership_state: 'current_member', payment_type: 'unknown')
  end

  test 'the first recorded send creates the row' do
    delivery = ReminderDelivery.record!('orientation', @user, anchor: @anchor, at: @now)

    assert_equal 1, delivery.sent_count
    assert_equal @now, delivery.first_sent_at
    assert_equal @now, delivery.last_sent_at
    assert_equal @anchor, delivery.anchor_at
    assert_equal @user, delivery.subject
  end

  test 'a later send increments the count and leaves the first send alone' do
    ReminderDelivery.record!('orientation', @user, anchor: @anchor, at: @now - 7.days)
    delivery = ReminderDelivery.record!('orientation', @user, anchor: @anchor, at: @now)

    assert_equal 1, ReminderDelivery.where(reminder_key: 'orientation', subject: @user).count
    assert_equal 2, delivery.sent_count
    assert_equal @now - 7.days, delivery.first_sent_at
    assert_equal @now, delivery.last_sent_at
  end

  test 'a moved anchor starts the count over' do
    ReminderDelivery.record!('orientation', @user, anchor: @anchor, at: @now - 7.days)
    moved = @now - 1.day
    delivery = ReminderDelivery.record!('orientation', @user, anchor: moved, at: @now)

    assert_equal 1, delivery.sent_count
    assert_equal moved, delivery.anchor_at
    assert_equal @now, delivery.first_sent_at
  end

  # Anchors are often computed rather than read off a column, so sub-second differences are
  # the same anchor rounded differently.
  test 'a barely different anchor is not a restart' do
    ReminderDelivery.record!('orientation', @user, anchor: @anchor, at: @now - 7.days)
    delivery = ReminderDelivery.record!('orientation', @user, anchor: @anchor + 0.4.seconds, at: @now)

    assert_equal 2, delivery.sent_count
  end

  test 'sequences for different reminders about the same subject are independent' do
    ReminderDelivery.record!('orientation', @user, anchor: @anchor, at: @now)
    ReminderDelivery.record!('slack_signup', @user, anchor: @anchor, at: @now)
    ReminderDelivery.record!('slack_signup', @user, anchor: @anchor, at: @now)

    assert_equal 1, ReminderDelivery.state_for('orientation', @user).sent_count
    assert_equal 2, ReminderDelivery.state_for('slack_signup', @user).sent_count
  end

  test 'state_for returns nothing for a subject that has never been reminded' do
    assert_nil ReminderDelivery.state_for('orientation', @user)
  end

  test 'index_for keys a page of subjects by id in one query' do
    other = User.create!(email: 'delivery-other@example.com', full_name: 'Other Subject',
                         service_account: false, membership_state: 'current_member', payment_type: 'unknown')
    ReminderDelivery.record!('orientation', @user, anchor: @anchor, at: @now)

    index = ReminderDelivery.index_for('orientation', [@user, other])

    assert_equal 1, index[@user.id].sent_count
    assert_nil index[other.id]
  end
end
