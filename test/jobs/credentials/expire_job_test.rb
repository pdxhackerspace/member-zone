require 'test_helper'

module Credentials
  class ExpireJobTest < ActiveJob::TestCase
    test 'expires and warns' do
      member = create_member
      provider = create_credential_provider
      lapsed = create_credential(provider: provider, user: member, expires_at: 1.hour.ago)
      soon = create_credential(provider: provider, user: member, expires_at: 2.days.from_now)

      ExpireJob.perform_now

      assert_equal 'expired', lapsed.reload.status
      assert_not_nil soon.reload.expiry_warning_sent_at
      assert_equal 1, QueuedMail.where(mailer_action: 'credential_expired', recipient: member).count
      assert_equal 1, QueuedMail.where(mailer_action: 'credential_expiring_soon', recipient: member).count
    end

    test 'running twice does not repeat anything' do
      member = create_member
      create_credential(provider: create_credential_provider, user: member, expires_at: 2.days.from_now)

      ExpireJob.perform_now

      assert_no_difference 'QueuedMail.count' do
        ExpireJob.perform_now
      end
    end

    test 'never calls the provider' do
      create_credential(provider: create_credential_provider, user: create_member, expires_at: 1.hour.ago)

      ExpireJob.perform_now

      assert_empty credential_calls
    end
  end
end
