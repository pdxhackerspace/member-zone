require 'test_helper'

module Credentials
  class RevokeAllTest < ActiveSupport::TestCase
    setup do
      @provider = create_credential_provider
      @a = create_member
      @b = create_member
      @credentials = [@a, @a, @b].map { |user| create_credential(provider: @provider, user: user) }
    end

    test 'revokes every live credential in the scope and tells each member once' do
      admin = users(:one)

      assert_difference -> { QueuedMail.where(mailer_action: 'credentials_revoked').count } => 2 do
        report = RevokeAll.call(@provider.credentials, by: admin)

        assert_equal @credentials.sort_by(&:id), report.revoked.sort_by(&:id)
        assert_empty report.failed
      end
      @credentials.each do |credential|
        assert_equal 'revoked', credential.reload.status
        assert_equal admin, credential.revoked_by
        assert_equal 'revoked_by_admin', credential.revocation_reason
      end
    end

    test 'the email says an administrator revoked them' do
      RevokeAll.call(@provider.credentials)

      assert_includes QueuedMail.where(mailer_action: 'credentials_revoked', recipient: @b).last.body_text,
                      'an administrator revoked it'
    end

    test 'only live credentials are touched' do
      done = create_credential(provider: @provider, user: @a, status: 'revoked')
      pending = create_credential(provider: @provider, user: @a, status: 'pending')

      report = RevokeAll.call(@provider.credentials)

      assert_not_includes report.candidates, done
      assert_not_includes report.candidates, pending
    end

    test 'can be limited to one member' do
      report = RevokeAll.call(Credential.where(user: @a))

      assert_equal 2, report.revoked.size
      assert_equal 'active', @credentials.last.reload.status
    end

    test 'a dry run lists candidates and changes nothing' do
      assert_no_difference ['QueuedMail.count', 'CredentialRun.count', 'Journal.count'] do
        report = RevokeAll.call(@provider.credentials, dry_run: true)

        assert_equal 3, report.candidates.size
        assert_empty report.revoked
      end
      assert(@credentials.all? { |credential| credential.reload.active? })
      assert_empty credential_calls
    end

    test 'failures are reported and not announced' do
      provider = create_credential_provider(env: { FAIL_REVOKE: '1' })
      credential = create_credential(provider: provider, user: @a)

      report = RevokeAll.call(provider.credentials)

      assert_equal [credential], report.failed
      assert_equal 'revoke_failed', credential.reload.status
    end

    test 'notification can be switched off' do
      assert_no_difference 'QueuedMail.count' do
        RevokeAll.call(@provider.credentials, notify: false)
      end
    end
  end
end
