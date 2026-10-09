require 'test_helper'

module Credentials
  class MemberSyncJobTest < ActiveJob::TestCase
    test 'syncs the member' do
      member = create_member
      credential = create_credential(provider: create_credential_provider, user: member)
      member.ban!

      MemberSyncJob.perform_now(member.id)

      assert_equal 'revoked', credential.reload.status
    end

    test 'a member who has gone is ignored' do
      assert_nothing_raised { MemberSyncJob.perform_now(0) }
    end

    test 'goes on the default queue' do
      assert_equal 'default', MemberSyncJob.new.queue_name
    end
  end
end
