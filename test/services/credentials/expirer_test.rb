require 'test_helper'

module Credentials
  class ExpirerTest < ActiveSupport::TestCase
    setup do
      @member = create_member
      @provider = create_credential_provider
      @now = Time.current
    end

    def mails(action)
      QueuedMail.where(mailer_action: action, recipient: @member)
    end

    def credential_expiring(in_days, **attributes)
      create_credential(provider: @provider, user: @member, expires_at: @now + in_days.days, **attributes)
    end

    test 'warns once, a week ahead' do
      soon = credential_expiring(6)

      assert_difference -> { mails('credential_expiring_soon').count } => 1 do
        report = Expirer.call(now: @now)
        assert_equal [soon], report.warned
      end

      assert_not_nil soon.reload.expiry_warning_sent_at
      assert_equal 'active', soon.status

      assert_no_difference -> { mails('credential_expiring_soon').count } do
        assert_empty Expirer.call(now: @now).warned
        assert_empty Expirer.call(now: @now + 1.day).warned
      end
    end

    test 'does not warn about a credential further out than a week' do
      far = credential_expiring(8)

      assert_no_difference -> { mails('credential_expiring_soon').count } do
        Expirer.call(now: @now)
      end
      assert_nil far.reload.expiry_warning_sent_at
    end

    test 'warns when it comes inside the window' do
      far = credential_expiring(8)
      Expirer.call(now: @now)

      assert_difference -> { mails('credential_expiring_soon').count } => 1 do
        Expirer.call(now: @now + 2.days)
      end
      assert_not_nil far.reload.expiry_warning_sent_at
    end

    test 'paused credentials are warned about and expired too' do
      paused = credential_expiring(3, status: 'paused')

      Expirer.call(now: @now)
      assert_not_nil paused.reload.expiry_warning_sent_at

      Expirer.call(now: @now + 4.days)
      assert_equal 'expired', paused.reload.status
    end

    test 'marks a credential past its date expired, journals it and emails the member' do
      lapsed = credential_expiring(-1)

      assert_difference -> { mails('credential_expired').count } => 1,
                        -> { Journal.where(action: 'credential_expired', user: @member).count } => 1 do
        report = Expirer.call(now: @now)
        assert_equal [lapsed], report.expired
      end

      assert_equal 'expired', lapsed.reload.status
    end

    test 'does not call revoke when a credential expires' do
      credential_expiring(-1)

      Expirer.call(now: @now)

      assert_not_includes credential_calls.map { |line| line.split.first }, 'revoke'
      assert_empty credential_calls
    end

    test 'a credential already past its date is expired without a warning first' do
      credential_expiring(-1)

      assert_no_difference -> { mails('credential_expiring_soon').count } do
        Expirer.call(now: @now)
      end
    end

    test 'credentials without a date, and finished ones, are never touched' do
      forever = create_credential(provider: @provider, user: @member)
      revoked = credential_expiring(-1, status: 'revoked')
      failed = credential_expiring(-1, status: 'revoke_failed')

      report = Expirer.call(now: @now)

      assert_empty report.expired + report.warned
      assert_equal 'active', forever.reload.status
      assert_equal 'revoked', revoked.reload.status
      assert_equal 'revoke_failed', failed.reload.status
    end

    test 'an opted-out member still has the credential expired but no email' do
      NotificationOptOut.opt_out!(@member, category: 'credentials')
      lapsed = credential_expiring(-1)
      credential_expiring(2)

      assert_no_difference 'QueuedMail.count' do
        Expirer.call(now: @now)
      end
      assert_equal 'expired', lapsed.reload.status
    end

    test 'a dry run reports and changes nothing' do
      soon = credential_expiring(3)
      lapsed = credential_expiring(-1)

      assert_no_difference ['QueuedMail.count', 'Journal.count'] do
        report = Expirer.call(dry_run: true, now: @now)

        assert_equal [soon], report.warned
        assert_equal [lapsed], report.expired
      end
      assert_nil soon.reload.expiry_warning_sent_at
      assert_equal 'active', lapsed.reload.status
    end

    test 'an expired credential cannot be rotated but can still be revoked by hand' do
      lapsed = credential_expiring(-1)
      Expirer.call(now: @now)

      assert_not lapsed.reload.rotatable?
      assert lapsed.revocable?
    end
  end
end
