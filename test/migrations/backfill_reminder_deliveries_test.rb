require 'test_helper'
require Rails.root.join('db/migrate/20260921120000_create_reminder_deliveries')

# The upgrade has to carry every reminder already in flight across to reminder_deliveries.
# Get it wrong and a member who has had three reminders either starts over or falls off the
# end of a sequence they were partway through, and nobody notices until the mail does not
# arrive. The table is already created by the time these run, so they drive the backfill
# directly against rows stamped the old way.
class BackfillReminderDeliveriesTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.local(2026, 9, 1, 7, 0, 0)
    @migration = CreateReminderDeliveries.new
    @migration.verbose = false
    ReminderDelivery.delete_all
  end

  test 'each stamped user reminder becomes one row starting at a count of one' do
    user = create_user('backfill-user@example.com')
    stamped = @now - 3.days
    user.update_columns(slack_signup_reminder_sent_at: stamped, orientation_reminder_sent_at: @now - 9.days)

    backfill(:backfill_user_reminders)

    slack = ReminderDelivery.state_for('slack_signup', user)
    assert_equal 1, slack.sent_count
    assert_equal stamped, slack.last_sent_at
    assert_equal stamped, slack.first_sent_at
    assert_equal 1, ReminderDelivery.state_for('orientation', user).sent_count
    assert_nil ReminderDelivery.state_for('payment_overdue', user)
  end

  test 'a user who was never reminded gets no row' do
    create_user('never-reminded@example.com')

    backfill(:backfill_user_reminders)

    assert_equal 0, ReminderDelivery.for_reminder('slack_signup').count
  end

  # The one reminder that already counted its sends, so the count carries over rather than
  # resetting everyone partway through a capped sequence back to the start.
  test 'the application link count carries over' do
    verification = ApplicationVerification.create!(
      email: 'backfill-link@example.com', confirmed_open_house: true, confirmed_code_of_conduct: true,
      created_at: @now - 9.days, expires_at: @now + 2.days
    )
    verification.update_columns(application_link_reminder_count: 2, application_link_reminder_sent_at: @now - 1.day)

    backfill(:backfill_application_link_reminders)

    delivery = ReminderDelivery.state_for('application_link', verification)
    assert_equal 2, delivery.sent_count
    assert_equal verification.created_at, delivery.anchor_at
  end

  # Parking stamped a column per phase, so how many stamps there are is how many reminders
  # went out — the only subject whose real count survived the old schema.
  test 'a parking notice counts its phase stamps and spans them' do
    notice = create_parking_notice
    first = @now - 10.days
    last = @now - 2.days
    notice.update_columns(pre_expiration_reminder_sent_at: first, expiration_notice_sent_at: @now - 7.days,
                          overdue_reminder_sent_at: last)

    backfill(:backfill_parking_notice_reminders)

    delivery = ReminderDelivery.state_for('parking_notices', notice)
    assert_equal 3, delivery.sent_count
    assert_equal first, delivery.first_sent_at
    assert_equal last, delivery.last_sent_at
    assert_equal notice.expires_at, delivery.anchor_at
  end

  test 'a cleared parking notice with no stamps gets no row' do
    notice = create_parking_notice

    backfill(:backfill_parking_notice_reminders)

    assert_nil ReminderDelivery.state_for('parking_notices', notice)
  end

  test 'a reminded application anchors on its submission' do
    application = MembershipApplication.create!(
      email: 'backfill-stale@example.com', status: 'submitted', submitted_at: @now - 10.days
    )
    application.update_columns(application_reminder_sent_at: @now - 2.days)

    backfill(:backfill_staff_application_reminders)

    delivery = ReminderDelivery.state_for('staff_application', application)
    assert_equal 1, delivery.sent_count
    assert_equal application.submitted_at, delivery.anchor_at
  end

  # A backfilled user row carries no anchor, so the first send after the upgrade must adopt
  # whatever anchor it is given rather than reading as a restart and discarding the count.
  test 'the first send after the upgrade continues a backfilled sequence' do
    user = create_user('backfill-continues@example.com')
    user.update_columns(orientation_reminder_sent_at: @now - 14.days)
    backfill(:backfill_user_reminders)

    delivery = ReminderDelivery.record!('orientation', user, anchor: @now - 28.days, at: @now)

    assert_equal 2, delivery.sent_count
    assert_equal @now - 28.days, delivery.anchor_at
  end

  private

  def backfill(method)
    @migration.send(method)
  end

  def create_user(email)
    User.create!(email: email, full_name: email.split('@').first.titleize, service_account: false,
                 membership_state: 'current_member', payment_type: 'unknown')
  end

  def create_parking_notice
    owner = create_user("parking-#{SecureRandom.hex(4)}@example.com")
    ParkingNotice.create!(
      user: owner,
      issued_by: owner,
      notice_type: 'permit',
      status: 'active',
      expires_at: @now - 12.days,
      description: 'Backfill subject',
      location: 'Main Area'
    )
  end
end
