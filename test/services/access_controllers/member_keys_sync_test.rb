require 'test_helper'

module AccessControllers
  class MemberKeysSyncTest < ActiveSupport::TestCase
    test 'user_notice describes syncing controllers' do
      assert_match(/syncing in the background/i, MemberKeysSync.user_notice(2))
      assert_match(/Access Controllers/i, MemberKeysSync.user_notice(0))
    end
  end
end
