require 'test_helper'

class ApiTokenExpiryEligibilityTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    set_reminder_cadence('api_token_expiry', enabled: true, start_offset_days: -14, interval_days: 7, max_reminders: 3)
    @member = users(:two)
    @admin = users(:one)
    @admin.update_columns(is_admin: true)
  end

  test 'a token is due two weeks before it expires' do
    token = token_expiring_in(10.days)

    assert_includes eligibility.due, token
  end

  test 'a token further out is not due yet' do
    token = token_expiring_in(30.days)

    assert_not_includes eligibility.due, token
  end

  test 'revoked, suspended, and expired tokens are not due' do
    revoked = token_expiring_in(5.days)
    revoked.revoke!(by: @member)
    suspended = token_expiring_in(5.days)
    suspended.suspend!(by: @member)
    expired = token_expiring_in(5.days)
    expired.update_columns(expires_at: 1.hour.ago)

    due = eligibility.due
    [revoked, suspended, expired].each { |token| assert_not_includes due, token }
  end

  test 'a token whose holder is inactive is not due' do
    token = token_expiring_in(5.days)
    @member.update_columns(membership_state: 'inactive_member')

    assert_not_includes eligibility.due, token
  end

  test 'the contact is reminded while they can be reached' do
    token = token_expiring_in(5.days)

    assert_equal [@member], eligibility.recipients(token)
    assert_not eligibility.contact_unreachable?(token)
  end

  test 'token managers are reminded when the contact is inactive' do
    manager = users(:three)
    grant_privileges(manager, 'api.tokens.manage')
    token = service_token_expiring_in(5.days, contact: @member)
    @member.update_columns(membership_state: 'inactive_member')

    assert eligibility.contact_unreachable?(token)
    assert_equal [@admin, manager].map(&:id).sort, eligibility.recipients(token).map(&:id).sort
  end

  test 'token managers are reminded when there is no contact' do
    token = service_token_expiring_in(5.days, contact: nil)
    token.update_columns(contact_user_id: nil)

    assert_equal [@admin], eligibility.recipients(ApiToken.find(token.id))
  end

  test 'stops after the maximum number of reminders' do
    token = token_expiring_in(3.days)
    record_reminder_sent('api_token_expiry', token, at: 8.days.ago, times: 3)

    assert_not_includes eligibility.due, token
  end

  test 'waits out the interval between reminders' do
    token = token_expiring_in(5.days)
    record_reminder_sent('api_token_expiry', token, at: 2.days.ago, times: 1)

    assert_not_includes eligibility.due, token
  end

  test 'extending a token starts the sequence over for the next expiry' do
    token = token_expiring_in(3.days)
    record_reminder_sent('api_token_expiry', token, at: 1.day.ago, times: 3)
    token.extend!(by: @member)

    assert_equal 0, eligibility.reminders_sent(token)
    travel_to(token.expires_at - 10.days) { assert_includes eligibility.due, token }
  end

  test 'the run emails the contact and counts the send' do
    token = token_expiring_in(10.days)

    assert_enqueued_emails 1 do
      Reminders::NotifyApiTokenExpiry.call
    end

    assert_equal 1, eligibility.reminders_sent(token)
    assert_not_includes eligibility.due, token
  end

  test 'the run emails every manager when nobody on the token can be reached' do
    grant_privileges(users(:three), 'api.tokens.manage')
    service_token_expiring_in(10.days, contact: nil).update_columns(contact_user_id: nil)

    assert_enqueued_emails 2 do
      Reminders::NotifyApiTokenExpiry.call
    end
  end

  test 'the run sends nothing when the reminder is disabled' do
    token_expiring_in(10.days)
    set_reminder_cadence('api_token_expiry', enabled: false)

    assert_no_enqueued_emails { Reminders::NotifyApiTokenExpiry.call }
  end

  test 'the job runs the notifier' do
    token_expiring_in(10.days)

    assert_enqueued_emails 1 do
      ApiTokenExpiryReminderJob.perform_now
    end
  end

  test 'total_expiring counts tokens inside the window' do
    token_expiring_in(5.days)
    token_expiring_in(40.days)

    assert_equal 1, eligibility.total_expiring
  end

  private

  def eligibility
    Reminders::ApiTokenExpiryEligibility
  end

  def token_expiring_in(duration)
    ApiToken.create!(user: @member, created_by: @member, name: "Token #{SecureRandom.hex(2)}",
                     expires_at: duration.from_now)
  end

  def service_token_expiring_in(duration, contact:)
    kiosk = create_service_account
    ApiToken.create!(user: kiosk, created_by: @admin, contact_user: contact || @admin, name: 'Kiosk',
                     expires_at: duration.from_now)
  end
end
