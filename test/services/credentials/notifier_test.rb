require 'test_helper'

module Credentials
  class NotifierTest < ActiveSupport::TestCase
    SECRET = 'abcd-secret-value-wxyz'.freeze

    setup do
      @member = create_member
      @provider = create_credential_provider
      @credential = create_credential(provider: @provider, user: @member, label: 'laptop CLI',
                                      expires_at: Time.zone.local(2026, 11, 3, 12))
    end

    def mails(action)
      QueuedMail.where(mailer_action: action, recipient: @member)
    end

    test 'expiring_soon queues a message naming the credential and its date' do
      assert_difference -> { mails('credential_expiring_soon').count } => 1 do
        Notifier.expiring_soon(@credential)
      end

      mail = mails('credential_expiring_soon').last
      assert_includes mail.subject, 'expires soon'
      assert_includes mail.body_text, 'Fixture OAuth client - laptop CLI'
      assert_includes mail.body_text, 'November 3, 2026'
      assert_includes mail.body_text, '/credentials'
    end

    test 'expired queues a message' do
      Notifier.expired(@credential)

      mail = mails('credential_expired').last
      assert_includes mail.body_text, 'has expired'
      assert_includes mail.body_text, 'Fixture OAuth client - laptop CLI'
    end

    test 'revoked lists every credential and the reason' do
      other = create_credential(provider: @provider, user: @member, label: 'ci')

      Notifier.revoked(@member, [@credential, other], reason: 'member_inactive')

      mail = mails('credentials_revoked').last
      assert_includes mail.body_text, '- Fixture OAuth client - laptop CLI'
      assert_includes mail.body_text, '- Fixture OAuth client - ci'
      assert_includes mail.body_text, 'your membership is no longer active'
      assert_includes mail.body_html, '<li>Fixture OAuth client - ci</li>'
    end

    test 'each reason has its own wording and an unknown one a safe default' do
      assert_equal 'your key access is paused', Notifier::REVOKED_REASONS['key_access_paused']
      Notifier.revoked(@member, [@credential], reason: 'something_new')
      assert_includes mails('credentials_revoked').last.body_text, 'it was needed'
    end

    test 'html in a label is escaped in the html body' do
      @credential.update!(label: '<script>alert(1)</script>')

      Notifier.revoked(@member, [@credential], reason: 'member_inactive')

      assert_not_includes mails('credentials_revoked').last.body_html, '<script>'
    end

    test 'an opted-out member is not emailed' do
      NotificationOptOut.opt_out!(@member, category: 'credentials')

      assert_no_difference 'QueuedMail.count' do
        Notifier.expiring_soon(@credential)
        Notifier.expired(@credential)
        Notifier.revoked(@member, [@credential], reason: 'member_inactive')
      end
    end

    test 'a member without an email address is skipped quietly' do
      @member.update_columns(email: nil)

      assert_no_difference 'QueuedMail.count' do
        assert_nil Notifier.expired(@credential)
      end
    end

    test 'emails never carry a secret, a hint or the handle' do
      @credential.update!(external_id: 'ext-handle-9999')
      Notifier.expiring_soon(@credential)
      Notifier.expired(@credential)
      Notifier.revoked(@member, [@credential], reason: 'member_inactive')

      QueuedMail.where(recipient: @member).find_each do |mail|
        [mail.subject, mail.body_html, mail.body_text, mail.mailer_args.to_json].each do |text|
          assert_not_includes text, SECRET
          assert_not_includes text, 'abcd…wxyz'
          assert_not_includes text, 'ext-handle-9999'
          assert_not_includes text, @credential.request_id
        end
      end
    end

    test 'uses the editable template when it is enabled' do
      EmailTemplate.seed_defaults!
      EmailTemplate.find_by!(key: 'credential_expired').update!(subject: 'Custom {{credential_name}} subject')

      Notifier.expired(@credential)

      assert_equal 'Custom Fixture OAuth client - laptop CLI subject', mails('credential_expired').last.subject
    end

    test 'a regenerated message keeps its content' do
      EmailTemplate.seed_defaults!
      Notifier.revoked(@member, [@credential], reason: 'member_inactive')
      mail = mails('credentials_revoked').last

      mail.regenerate!

      assert_includes mail.reload.body_text, 'Fixture OAuth client - laptop CLI'
    end

    test 'a regenerated fallback message keeps its content' do
      Notifier.expiring_soon(@credential)
      mail = mails('credential_expiring_soon').last

      mail.regenerate!

      assert_includes mail.reload.body_text, 'November 3, 2026'
    end
  end
end
