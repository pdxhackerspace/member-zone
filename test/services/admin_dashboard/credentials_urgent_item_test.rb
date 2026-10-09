require 'test_helper'

module AdminDashboard
  class CredentialsUrgentItemTest < ActiveSupport::TestCase
    def credential_item
      UrgentItems.call.find { |item| item.id == :credentials }
    end

    test 'no item when nothing is wrong' do
      create_credential_provider

      assert_nil credential_item
    end

    test 'an unhealthy provider is urgent' do
      create_credential_provider(health: 'unhealthy')

      item = credential_item

      assert item
      assert_includes item.title, '1 issue'
      assert_includes item.detail, '1 unhealthy provider'
      assert item.url.end_with?(Rails.application.routes.url_helpers.credential_providers_path)
    end

    test 'failing revocations and stuck issues are urgent too' do
      provider = create_credential_provider
      create_credential(provider: provider, user: create_member, status: 'revoke_failed')
      stuck = create_credential(provider: provider, user: create_member, status: 'pending')
      stuck.update_columns(created_at: 1.hour.ago)

      item = credential_item

      assert_includes item.title, '2 issues'
      assert_includes item.detail, '1 revocation(s) failing'
      assert_includes item.detail, '1 issue(s) never finished'
    end

    test 'a disabled provider does not count as unhealthy' do
      create_credential_provider(health: 'unhealthy', enabled: false)

      assert_nil credential_item
    end
  end
end
