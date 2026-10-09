require 'test_helper'

module Credentials
  class ReconcileJobTest < ActiveJob::TestCase
    test 'syncs mismatched members, retries revokes and fails stale pending rows' do
      provider = create_credential_provider
      member = create_member
      mismatched = create_credential(provider: provider, user: member)
      member.update_columns(membership_state: 'banned_member', active: false)
      retry_me = create_credential(provider: provider, user: create_member, status: 'revoke_failed',
                                   revocation_reason: 'revoked_by_admin', last_revoke_error_at: 3.days.ago)
      stale = create_credential(provider: provider, user: create_member, status: 'pending', external_id: nil)
      stale.update_columns(created_at: 1.hour.ago)

      ReconcileJob.perform_now

      assert_equal 'revoked', mismatched.reload.status
      assert_equal 'revoked', retry_me.reload.status
      assert_equal 'failed', stale.reload.status
    end

    test 'does nothing when there is nothing to do' do
      create_credential(provider: create_credential_provider, user: create_member)

      assert_nothing_raised { ReconcileJob.perform_now }
      assert_empty credential_calls
    end
  end
end
