require 'test_helper'

module Announcers
  class ArrivalDispatcherTest < ActiveJob::TestCase
    setup do
      DefaultSetting.instance.update!(arrival_locations: ['unit2 front door'])
      @user = users(:one)
      @user.update!(announce_arrivals: true, greeting_name: 'Ada')
      @announcer = create_announcer
      @user.announcer_subscriptions.create!(announcer: @announcer)
    end

    def arrival(action: 'opened', location: 'unit2 front door', logged_at: Time.current, user: @user)
      AccessLog.create!(user: user, name: user.full_name, action: action, location: location, logged_at: logged_at)
    end

    test 'queues a run for each announcer the member chose' do
      other = create_announcer
      @user.announcer_subscriptions.create!(announcer: other)
      create_announcer # not chosen

      runs = nil
      assert_enqueued_jobs(2, only: RunJob) { runs = ArrivalDispatcher.call(arrival) }

      assert_equal [@announcer, other].sort_by(&:id), runs.map(&:announcer).sort_by(&:id)
      assert(runs.all? { |run| run.status == 'queued' && run.user == @user })
    end

    test 'nothing for a member who has not switched announcements on' do
      @user.update!(announce_arrivals: false)

      assert_empty ArrivalDispatcher.call(arrival)
    end

    test 'nothing for a member without access or without a name to use' do
      @user.update!(greeting_name: nil, do_not_greet: true)
      assert_empty ArrivalDispatcher.call(arrival)

      @user.update!(do_not_greet: false, greeting_name: 'Ada')
      @user.ban!
      assert_empty ArrivalDispatcher.call(arrival)
    end

    test 'nothing for departures, inside doors or stale entries' do
      assert_empty ArrivalDispatcher.call(arrival(action: 'locked'))
      assert_empty ArrivalDispatcher.call(arrival(location: 'unit2 shop door'))
      assert_empty ArrivalDispatcher.call(arrival(logged_at: 1.hour.ago))
    end

    test 'skips disabled announcers' do
      @announcer.update!(enabled: false)

      assert_empty ArrivalDispatcher.call(arrival)
    end

    test 'does not announce the same member again inside the repeat window' do
      assert_equal 1, ArrivalDispatcher.call(arrival).size
      assert_empty ArrivalDispatcher.call(arrival)

      travel 121.minutes do
        assert_equal 1, ArrivalDispatcher.call(arrival).size
      end
    end
  end
end
