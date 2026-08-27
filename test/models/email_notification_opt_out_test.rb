require 'test_helper'

class EmailNotificationOptOutTest < ActiveSupport::TestCase
  test 'opt_out and opt_in round trip by email' do
    email = 'applicant-opt-out@example.com'
    assert_not EmailNotificationOptOut.opted_out?(email, category: 'application_link')

    EmailNotificationOptOut.opt_out!(email, category: 'application_link', channel: 'email')
    assert EmailNotificationOptOut.opted_out?(email, category: 'application_link')

    EmailNotificationOptOut.opt_in!(email, category: 'application_link', channel: 'email')
    assert_not EmailNotificationOptOut.opted_out?(email, category: 'application_link')
  end

  test 'lookup works after encryption' do
    email = 'encrypted-opt-out@example.com'
    EmailNotificationOptOut.opt_out!(email, category: 'application_link')

    record = EmailNotificationOptOut.by_email(email).first
    assert record
    assert_equal email, record.email
  end

  test 'opt_out! is idempotent for the same email' do
    email = 'duplicate-opt-out@example.com'

    assert_difference -> { EmailNotificationOptOut.count }, 1 do
      EmailNotificationOptOut.opt_out!(email, category: 'application_link')
      EmailNotificationOptOut.opt_out!(email, category: 'application_link')
    end
  end
end
