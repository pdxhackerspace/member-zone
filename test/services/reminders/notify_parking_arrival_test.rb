require 'test_helper'

module Reminders
  class NotifyParkingArrivalTest < ActiveSupport::TestCase
    include ActionMailer::TestHelper

    setup do
      DefaultSetting.instance.update!(arrival_locations: ['unit2 front door'])
      ReminderSetting.seed_defaults!
      @setting = ReminderSetting.find_by!(key: 'parking_arrival')
      @setting.update!(enabled: true, allow_opt_out: true, repeat_after_minutes: 120)
      @user = users(:one)
      @notice = parking_notices(:active_permit)
      @notice.update_columns(created_at: 1.day.ago)
    end

    test 'an arrival with an open notice sends one email listing it' do
      assert_enqueued_emails 1 do
        NotifyParkingArrival.call(arrival)
      end

      body = ParkingArrivalMessage.call(@user, [@notice])
      assert_includes body[:notices_html], 'Clear this permit'
      assert_includes body[:notices_html], @notice.description
      assert_includes body[:notices_text], 'Clear this permit:'
      assert_match %r{/parking_clear/}, body[:notices_html]
    end

    test 'a second scan inside the repeat window sends nothing' do
      NotifyParkingArrival.call(arrival)

      assert_no_enqueued_emails { NotifyParkingArrival.call(arrival) }

      travel 121.minutes do
        assert_enqueued_emails 1 do
          NotifyParkingArrival.call(arrival)
        end
      end
    end

    test 'a repeat window of zero emails every arrival, including a notice just issued' do
      @setting.update!(repeat_after_minutes: 0)
      @notice.update_columns(created_at: Time.current)

      assert_enqueued_emails 1 do
        NotifyParkingArrival.call(arrival)
      end
      assert_enqueued_emails 1 do
        NotifyParkingArrival.call(arrival)
      end
    end

    test 'a notice issued inside the window is left out' do
      @notice.update_columns(created_at: 1.minute.ago)

      assert_no_enqueued_emails { NotifyParkingArrival.call(arrival) }
    end

    test 'a notice waiting on staff clearance is left out' do
      @notice.update!(clearance_requested_at: Time.current, clearance_requested_by: @user)

      assert_no_enqueued_emails { NotifyParkingArrival.call(arrival) }
    end

    test 'a flagged notice offers a clearance request rather than a clear button' do
      @notice.update!(requires_admin_clearance: true)

      body = ParkingArrivalMessage.call(@user, [@notice])

      assert_includes body[:notices_html], 'Request clearance'
      assert_not_includes body[:notices_html], 'Clear this permit'
    end

    test 'nothing goes out while the reminder is disabled' do
      @setting.update!(enabled: false)

      assert_no_enqueued_emails { NotifyParkingArrival.call(arrival) }
    end

    test 'a member who hushed it is not emailed' do
      NotificationOptOut.opt_out!(@user, category: 'parking_arrival')

      assert_no_enqueued_emails { NotifyParkingArrival.call(arrival) }
    end

    test 'an inactive member with an open notice is emailed' do
      @user.transition_to!('inactive_member')

      assert_enqueued_emails 1 do
        NotifyParkingArrival.call(arrival)
      end
    end

    test 'a banned member is skipped' do
      @user.ban!

      assert_no_enqueued_emails { NotifyParkingArrival.call(arrival) }
    end

    test 'a service account is skipped' do
      @user.update!(service_account: true)

      assert_no_enqueued_emails { NotifyParkingArrival.call(arrival) }
    end

    test 'a member without an email address is skipped' do
      @user.update_columns(email: nil, email_lookup_digest: nil)

      assert_no_enqueued_emails { NotifyParkingArrival.call(arrival) }
    end

    test 'departures, inside doors, and stale scans send nothing' do
      assert_no_enqueued_emails { NotifyParkingArrival.call(arrival(action: 'locked')) }
      assert_no_enqueued_emails { NotifyParkingArrival.call(arrival(location: 'unit2 shop door')) }
      assert_no_enqueued_emails { NotifyParkingArrival.call(arrival(logged_at: 1.hour.ago)) }
    end

    test 'a description cannot inject markup into the email' do
      @notice.update!(description: '<script>alert(1)</script> {{notices_html}}')

      body = ParkingArrivalMessage.call(@user, [@notice])

      assert_includes body[:notices_html], '&lt;script&gt;'
      assert_not_includes body[:notices_html], '<script>'
      assert_not_includes body[:notices_text], '{{'
    end

    def arrival(action: 'opened', location: 'unit2 front door', logged_at: Time.current, user: @user)
      AccessLog.create!(user: user, name: user.full_name, action: action, location: location, logged_at: logged_at)
    end
  end
end
