require 'test_helper'

module Credentials
  class MemberSyncTest < ActiveSupport::TestCase
    setup do
      @member = create_member
      @provider = create_credential_provider
      @pausable = create_credential(provider: @provider, user: @member, label: 'one')
    end

    def calls
      credential_calls.map { |line| line.split.first }
    end

    def mails(action = 'credentials_revoked')
      QueuedMail.where(mailer_action: action, recipient: @member)
    end

    test 'a member who is no longer active has every live credential revoked' do
      paused = create_credential(provider: @provider, user: @member, status: 'paused')
      failing = create_credential(provider: @provider, user: @member, status: 'revoke_failed')
      @member.ban!

      summary = MemberSync.call(@member)

      assert_equal [@pausable, paused, failing].sort_by(&:id), summary.revoked.sort_by(&:id)
      [@pausable, paused, failing].each do |credential|
        assert_equal 'revoked', credential.reload.status
        assert_equal 'member_inactive', credential.revocation_reason
      end
      assert_equal %w[revoke revoke revoke], calls
    end

    test 'credentials that are not live are left alone' do
      done = create_credential(provider: @provider, user: @member, status: 'revoked')
      expired = create_credential(provider: @provider, user: @member, status: 'expired')
      @member.ban!

      MemberSync.call(@member)

      assert_equal 'revoked', done.reload.status
      assert_equal 'expired', expired.reload.status
      assert_equal 1, calls.size
    end

    test 'only the member in question is touched' do
      other = create_credential(provider: @provider, user: create_member)
      @member.ban!

      MemberSync.call(@member)

      assert_equal 'active', other.reload.status
    end

    test 'the member is told once, listing what was revoked' do
      create_credential(provider: @provider, user: @member, label: 'two')
      @member.ban!

      assert_difference -> { mails.count } => 1 do
        MemberSync.call(@member)
      end

      body = mails.last.body_text
      assert_includes body, 'Fixture OAuth client - one'
      assert_includes body, 'Fixture OAuth client - two'
      assert_includes body, 'your membership is no longer active'
    end

    test 'a revoke that fails is reported, retried later and left out of the email' do
      provider = create_credential_provider(env: { FAIL_REVOKE: '1' })
      broken = create_credential(provider: provider, user: @member, label: 'broken')
      @member.ban!

      summary = MemberSync.call(@member)

      assert_equal [broken], summary.failed
      assert_equal [@pausable], summary.revoked
      assert_equal 'revoke_failed', broken.reload.status
      assert_not_includes mails.last.body_text, 'broken'
    end

    test 'no email when nothing could be revoked' do
      provider = create_credential_provider(env: { FAIL_REVOKE: '1' })
      @pausable.destroy
      create_credential(provider: provider, user: @member)
      @member.ban!

      assert_no_difference -> { mails.count } do
        MemberSync.call(@member)
      end
    end

    test 'an opted-out member is not emailed but is still revoked' do
      NotificationOptOut.opt_out!(@member, category: 'credentials')
      @member.ban!

      assert_no_difference -> { mails.count } do
        MemberSync.call(@member)
      end
      assert_equal 'revoked', @pausable.reload.status
    end

    test 'pausing key access pauses credentials at a provider that supports it' do
      @member.pause_key_access!

      summary = MemberSync.call(@member)

      assert_equal [@pausable], summary.paused
      assert_equal 'paused', @pausable.reload.status
      assert_equal %w[pause], calls
      assert_empty mails, 'a pause is not announced as a revocation'
    end

    test 'pausing key access revokes credentials at a provider that cannot pause' do
      provider = create_credential_provider(script: 'single_key.rb')
      single = create_credential(provider: provider, user: @member, label: 'key')
      @member.pause_key_access!

      summary = MemberSync.call(@member)

      assert_equal [@pausable], summary.paused
      assert_equal [single], summary.revoked
      assert_equal 'revoked', single.reload.status
      assert_equal 'key_access_paused', single.revocation_reason
      assert_includes mails.last.body_text, 'your key access is paused'
      assert_includes mails.last.body_text, 'Fixture API key - key'
    end

    test 'a pause that fails is reported and the credential stays active' do
      provider = create_credential_provider(env: { FAIL_PAUSE: '1' })
      credential = create_credential(provider: provider, user: @member)
      @member.pause_key_access!

      summary = MemberSync.call(@member)

      assert_includes summary.failed, credential
      assert_equal 'active', credential.reload.status
    end

    test 'resuming key access resumes paused credentials' do
      @pausable.update!(status: 'paused', paused_at: 1.hour.ago)
      @member.update_columns(key_access_paused: false)

      summary = MemberSync.call(@member)

      assert_equal [@pausable], summary.resumed
      assert_equal 'active', @pausable.reload.status
      assert_equal %w[resume], calls
    end

    test 'an active member with active credentials has nothing to do' do
      summary = MemberSync.call(@member)

      assert_empty summary.revoked + summary.paused + summary.resumed + summary.failed
      assert_empty calls
    end

    test 'paused key access and an inactive membership together revoke rather than pause' do
      @member.pause_key_access!
      @member.ban!

      MemberSync.call(@member)

      assert_equal 'revoked', @pausable.reload.status
      assert_equal 'member_inactive', @pausable.revocation_reason
    end

    test 'reactivating a member restores nothing' do
      @member.ban!
      MemberSync.call(@member)
      @member.unban!

      MemberSync.call(@member)

      assert_equal 'revoked', @pausable.reload.status
    end

    test 'credentials of a disabled provider are still revoked' do
      @provider.update!(enabled: false)
      @member.ban!

      MemberSync.call(@member)

      assert_equal 'revoked', @pausable.reload.status
    end
  end
end
