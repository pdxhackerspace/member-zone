require 'test_helper'

class AccessControllerTypeTest < ActiveSupport::TestCase
  test 'requires a program in an access script directory' do
    type = AccessControllerType.new(name: 'Doors', script_path: access_script('door_lock.sh'))
    assert_predicate type, :valid?

    type.script_path = '/bin/sh'
    assert_not type.valid?
    assert_includes type.errors[:script_path].to_sentence, 'access script directory'
  end
end
