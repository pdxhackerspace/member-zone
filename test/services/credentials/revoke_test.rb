require 'test_helper'

module Credentials
  class RevokeTest < ActiveSupport::TestCase
    setup do
      @member = create_member
      @admin = users(:one)
      @provider = create_credential_provider
      @credential = create_credential(provider: @provider, user: @member)
    end

    test 'revokes at the provider and marks the credential revoked' do
      result = Revoke.call(@credential, reason: 'revoked_by_member', by: @member)

      assert_predicate result, :ok?
      @credential.reload
      assert_equal 'revoked', @credential.status
      assert_not_nil @credential.revoked_at
      assert_equal @member, @credential.revoked_by
      assert_equal 'revoked_by_member', @credential.revocation_reason
    end

    test 'tells the program which credential, why, and for whom' do
      Revoke.call(@credential, reason: 'revoked_by_admin', by: @admin)

      input = credential_stdin('revoke')
      assert_equal @credential.request_id, input['request_id']
      assert_equal @credential.external_id, input['external_id']
      assert_equal 'revoked_by_admin', input['reason']
      assert_equal @member.authentik_id, input['member']['uid']
      assert_equal 'revoke', credential_calls.last.split.first
    end

    test 'writes a journal entry naming who revoked it' do
      assert_difference -> { Journal.where(action: 'credential_revoked', user: @member).count } => 1 do
        Revoke.call(@credential, reason: 'revoked_by_admin', by: @admin)
      end

      journal = Journal.where(action: 'credential_revoked').last
      assert_equal @admin, journal.actor_user
      assert_equal 'Revoked by an administrator', journal.changes_json.dig('credential', 'reason')
    end

    test 'logs a run' do
      Revoke.call(@credential, reason: 'revoked_by_member')
      assert_equal 'success', @credential.credential_runs.find_by(action: 'revoke').status
    end

    test 'a failure leaves the credential revoke_failed with the attempt counted' do
      provider = create_credential_provider(env: { FAIL_REVOKE: '1' })
      credential = create_credential(provider: provider, user: @member)

      result = Revoke.call(credential, reason: 'member_inactive')

      assert_not_predicate result, :ok?
      assert_equal 'Exited with status 1', result.error
      credential.reload
      assert_equal 'revoke_failed', credential.status
      assert_equal 1, credential.revoke_attempts
      assert_not_nil credential.last_revoke_error_at
      assert_equal 'member_inactive', credential.revocation_reason
      assert_nil credential.revoked_at
      assert_equal 'failed', credential.credential_runs.find_by(action: 'revoke').status
    end

    test 'a failure writes a journal entry with the error' do
      provider = create_credential_provider(env: { FAIL_REVOKE: '1' })
      credential = create_credential(provider: provider, user: @member)

      Revoke.call(credential, reason: 'member_inactive')

      journal = Journal.where(action: 'credential_revoke_failed', user: @member).last
      assert_equal 'Exited with status 1', journal.changes_json.dig('credential', 'error')
    end

    test 'retrying counts each attempt and succeeds once the provider recovers' do
      provider = create_credential_provider(env: { FAIL_REVOKE: '1' })
      credential = create_credential(provider: provider, user: @member)
      2.times { Revoke.call(credential.reload, reason: 'member_inactive') }
      assert_equal 2, credential.reload.revoke_attempts

      provider.update!(environment_variables: "STATE_DIR=#{credential_state_dir}")
      result = Revoke.call(credential.reload, reason: credential.revocation_reason)

      assert_predicate result, :ok?
      assert_equal 'revoked', credential.reload.status
      assert_equal 2, credential.revoke_attempts
    end

    test 'an already revoked credential is a no-op that does not run the program' do
      @credential.update!(status: 'revoked', revoked_at: 1.day.ago)

      result = Revoke.call(@credential, reason: 'revoked_by_member')

      assert_predicate result, :ok?
      assert_empty credential_calls
    end

    test 'a credential that cannot be revoked is refused without running the program' do
      pending = create_credential(provider: @provider, user: @member, status: 'pending', external_id: nil)
      failed = create_credential(provider: @provider, user: @member, status: 'failed')

      [pending, failed].each do |credential|
        result = Revoke.call(credential, reason: 'revoked_by_member')
        assert_not_predicate result, :ok?
        assert_equal 'This credential cannot be revoked.', result.error
      end
      assert_empty credential_calls
    end

    test 'an expired credential can still be revoked by hand' do
      @credential.update!(status: 'expired')

      assert_predicate Revoke.call(@credential, reason: 'revoked_by_admin'), :ok?
      assert_equal 'revoked', @credential.reload.status
    end

    test 'a paused credential is revoked too' do
      @credential.update!(status: 'paused')

      assert_predicate Revoke.call(@credential, reason: 'member_inactive'), :ok?
    end

    test 'a disabled or unhealthy provider is still asked to revoke' do
      @provider.update!(enabled: false)
      @provider.record_health!('unhealthy', 'down')

      assert_predicate Revoke.call(@credential, reason: 'member_inactive'), :ok?
      assert_equal 'revoked', @credential.reload.status
    end

    test 'a provider that is not configured fails the revoke' do
      provider = create_credential_provider(env: { NOT_CONFIGURED: '1' })
      credential = create_credential(provider: provider, user: @member)

      result = Revoke.call(credential, reason: 'member_inactive')

      assert_not_predicate result, :ok?
      assert_equal 'revoke_failed', credential.reload.status
    end

    test 'journal can be skipped' do
      assert_no_difference 'Journal.count' do
        Revoke.call(@credential, reason: 'issue_incomplete', journal: false)
      end
    end

    test 'an unknown reason is rejected by validation rather than stored' do
      assert_raises(ActiveRecord::RecordInvalid) { Revoke.call(@credential, reason: 'because') }
    end
  end
end
