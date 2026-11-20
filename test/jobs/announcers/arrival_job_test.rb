require 'test_helper'

module Announcers
  class ArrivalJobTest < ActiveJob::TestCase
    setup do
      @access_log = AccessLog.create!(user: users(:one), action: 'opened', location: 'front', logged_at: Time.current)
    end

    test 'runs announcements and the parking reminder' do
      called = []

      replace_call(ArrivalDispatcher, ->(*) { called << :announce }) do
        replace_call(Reminders::NotifyParkingArrival, ->(*) { called << :parking }) do
          ArrivalJob.perform_now(@access_log.id)
        end
      end

      assert_equal %i[announce parking], called
    end

    test 'a parking reminder failure does not stop announcements' do
      called = []

      replace_call(ArrivalDispatcher, ->(*) { called << :announce }) do
        replace_call(Reminders::NotifyParkingArrival, ->(*) { raise 'boom' }) do
          assert_nothing_raised { ArrivalJob.perform_now(@access_log.id) }
        end
      end

      assert_equal [:announce], called
    end

    test 'an announcement failure does not stop the parking reminder' do
      called = []

      replace_call(ArrivalDispatcher, ->(*) { raise 'boom' }) do
        replace_call(Reminders::NotifyParkingArrival, ->(*) { called << :parking }) do
          assert_nothing_raised { ArrivalJob.perform_now(@access_log.id) }
        end
      end

      assert_equal [:parking], called
    end

    test 'a missing access log does nothing' do
      assert_nothing_raised { ArrivalJob.perform_now(-1) }
    end

    private

    def replace_call(klass, implementation)
      singleton = klass.singleton_class
      original = singleton.instance_method(:call)
      singleton.define_method(:call, implementation)
      yield
    ensure
      singleton.define_method(:call, original)
    end
  end
end
