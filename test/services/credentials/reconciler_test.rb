require 'test_helper'

module Credentials
  class ReconcilerTest < ActiveSupport::TestCase
    setup do
      @member = create_member
      @provider = create_credential_provider
      @now = Time.current
    end

    test 'backoff doubles from an hour and stops at a day' do
      assert_equal 1.hour, Reconciler.backoff(1)
      assert_equal 2.hours, Reconciler.backoff(2)
      assert_equal 4.hours, Reconciler.backoff(3)
      assert_equal 8.hours, Reconciler.backoff(4)
      assert_equal 16.hours, Reconciler.backoff(5)
      assert_equal 24.hours, Reconciler.backoff(6)
      assert_equal 24.hours, Reconciler.backoff(50)
      assert_equal 1.hour, Reconciler.backoff(0)
    end

    test 'syncs a member deactivated without the callback running' do
      credential = create_credential(provider: @provider, user: @member)
      @member.update_columns(membership_state: 'banned_member', active: false)

      report = Reconciler.call(now: @now)

      assert_includes report.users, @member
      assert_equal 'revoked', credential.reload.status
    end

    test 'syncs a member whose standing lapsed on a deadline nobody has materialized' do
      credential = create_credential(provider: @provider, user: @member)
      @member.update_columns(membership_state: 'inactive_member')
      assert_not @member.reload.active?

      Reconciler.call(now: @now)

      assert_equal 'revoked', credential.reload.status
    end

    test 'pauses credentials of a member whose key access was paused behind our back' do
      credential = create_credential(provider: @provider, user: @member)
      @member.update_columns(key_access_paused: true)

      Reconciler.call(now: @now)

      assert_equal 'paused', credential.reload.status
    end

    test 'resumes credentials of a member whose key access came back behind our back' do
      credential = create_credential(provider: @provider, user: @member, status: 'paused')

      Reconciler.call(now: @now)

      assert_equal 'active', credential.reload.status
    end

    test 'leaves members whose credentials already match their standing' do
      credential = create_credential(provider: @provider, user: @member)

      report = Reconciler.call(now: @now)

      assert_not_includes report.users, @member
      assert_equal 'active', credential.reload.status
      assert_empty credential_calls
    end

    test 'retries a failed revoke once its backoff has passed' do
      credential = create_credential(provider: @provider, user: @member, status: 'revoke_failed', revoke_attempts: 1,
                                     revocation_reason: 'revoked_by_admin', last_revoke_error_at: @now - 2.hours)

      report = Reconciler.call(now: @now)

      assert_equal [credential], report.retried
      assert_equal 'revoked', credential.reload.status
      assert_equal 'revoked_by_admin', credential.revocation_reason
    end

    test 'does not retry before the backoff has passed' do
      credential = create_credential(provider: @provider, user: @member, status: 'revoke_failed', revoke_attempts: 3,
                                     revocation_reason: 'revoked_by_admin', last_revoke_error_at: @now - 3.hours)

      report = Reconciler.call(now: @now)

      assert_empty report.retried
      assert_equal 'revoke_failed', credential.reload.status
      assert_empty credential_calls
    end

    test 'backoff is capped at a day however many attempts have failed' do
      stuck = create_credential(provider: @provider, user: @member, status: 'revoke_failed', revoke_attempts: 40,
                                revocation_reason: 'revoked_by_admin', last_revoke_error_at: @now - 23.hours)
      assert_empty Reconciler.call(now: @now).retried

      stuck.update_columns(last_revoke_error_at: @now - 25.hours)
      assert_equal [stuck], Reconciler.call(now: @now).retried
    end

    test 'a retry that fails again counts another attempt' do
      provider = create_credential_provider(env: { FAIL_REVOKE: '1' })
      credential = create_credential(provider: provider, user: @member, status: 'revoke_failed', revoke_attempts: 1,
                                     revocation_reason: 'revoked_by_admin', last_revoke_error_at: @now - 2.hours)

      Reconciler.call(now: @now)

      credential.reload
      assert_equal 'revoke_failed', credential.status
      assert_equal 2, credential.revoke_attempts
    end

    test 'a failed revoke with no recorded error time is retried straight away' do
      credential = create_credential(provider: @provider, user: @member, status: 'revoke_failed',
                                     revocation_reason: 'revoked_by_admin')

      assert_equal [credential], Reconciler.call(now: @now).retried
    end

    test 'a revoke the sync just attempted is not attempted twice in one run' do
      provider = create_credential_provider(env: { FAIL_REVOKE: '1' })
      create_credential(provider: provider, user: @member)
      @member.update_columns(membership_state: 'banned_member', active: false)

      Reconciler.call(now: @now)

      assert_equal(1, credential_calls.count { |line| line.start_with?('revoke') })
    end

    test 'marks a pending credential that never heard back as failed' do
      stale = create_credential(provider: @provider, user: @member, status: 'pending', external_id: nil)
      stale.update_columns(created_at: 1.hour.ago)
      fresh = create_credential(provider: @provider, user: @member, status: 'pending', external_id: nil)

      report = Reconciler.call(now: @now)

      assert_equal [stale], report.stale
      assert_equal 'failed', stale.reload.status
      assert_equal 'pending', fresh.reload.status
      assert_equal 1, Journal.where(action: 'credential_issue_incomplete', user: @member).count
    end

    test 'a dry run reports and changes nothing' do
      active = create_credential(provider: @provider, user: @member)
      failed = create_credential(provider: @provider, user: @member, status: 'revoke_failed',
                                 revocation_reason: 'revoked_by_admin')
      stale = create_credential(provider: @provider, user: @member, status: 'pending', external_id: nil)
      stale.update_columns(created_at: 1.hour.ago)
      @member.update_columns(membership_state: 'banned_member', active: false)

      assert_no_difference ['CredentialRun.count', 'Journal.count', 'QueuedMail.count'] do
        report = Reconciler.call(dry_run: true, now: @now)

        assert_includes report.users, @member
        assert_equal [failed], report.retried
        assert_equal [stale], report.stale
      end
      assert_equal 'active', active.reload.status
      assert_equal 'revoke_failed', failed.reload.status
      assert_equal 'pending', stale.reload.status
      assert_empty credential_calls
    end
  end
end
