require 'test_helper'

class AccessLogArrivalTest < ActiveSupport::TestCase
  setup do
    DefaultSetting.instance.update!(arrival_locations: ['unit2 front door'])
  end

  test 'opening or unlocking an outside door is an arrival' do
    assert AccessLog.new(action: 'opened', location: 'unit2 front door').arrival?
    assert AccessLog.new(action: 'unlocked', location: 'Unit2 Front Door').arrival?
  end

  test 'locking a door is never an arrival' do
    assert_not AccessLog.new(action: 'locked', location: 'unit2 front door').arrival?
  end

  test 'a door that is not an outside door is not an arrival' do
    assert_not AccessLog.new(action: 'opened', location: 'unit2 shop door').arrival?
    assert_not AccessLog.new(action: 'enabled', location: 'laser-access').arrival?
  end

  test 'arrival locations are trimmed and de-duplicated' do
    setting = DefaultSetting.instance
    setting.update!(arrival_locations: [' back door ', 'back door', '', nil])

    assert_equal ['back door'], setting.reload.arrival_locations
  end
end
