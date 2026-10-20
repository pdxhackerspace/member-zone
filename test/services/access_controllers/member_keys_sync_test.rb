require 'test_helper'

module AccessControllers
  class MemberKeysSyncTest < ActiveSupport::TestCase
    test 'user_notice describes syncing controllers' do
      assert_match(/syncing in the background/i, MemberKeysSync.user_notice(2))
      assert_match(/Access Controllers/i, MemberKeysSync.user_notice(0))
    end

    test 'key change notices omit syncing language when no controllers are enabled' do
      AccessController.delete_all

      assert_no_match(/are syncing/i, MemberKeysSync.rfid_removed_notice)
      assert_match(/No enabled access controllers/i, MemberKeysSync.rfid_removed_notice)
    end

    test 'key change notices describe syncing when controllers exist' do
      AccessController.create!(name: 'Flash test door', hostname: 'flash.local',
                               access_controller_type: access_controller_types(:door_lock))

      assert_match(/are syncing/i, MemberKeysSync.rfid_removed_notice)
    end
  end
end
