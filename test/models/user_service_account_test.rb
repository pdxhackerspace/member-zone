require 'test_helper'

class UserServiceAccountTest < ActiveSupport::TestCase
  test 'service_accounts scope returns only service accounts' do
    sa = create_service_account
    results = User.service_accounts
    assert_includes results, sa
    assert_not_includes results, users(:one)
  end

  test 'non_service_accounts scope excludes service accounts' do
    sa = create_service_account
    results = User.non_service_accounts
    assert_not_includes results, sa
    assert_includes results, users(:one)
  end

  test 'service account defaults to false' do
    user = User.new(authentik_id: 'sa-test', full_name: 'New User', payment_type: 'unknown')
    assert_not user.service_account?
  end

  test 'service account can be set to true' do
    sa = create_service_account(active: true)
    assert sa.service_account?
    assert sa.active?
  end

  test 'service account active flag is independent of membership status' do
    sa = create_service_account(active: true)
    assert sa.active?, 'service account should stay active regardless of unknown status'

    sa.update!(active: false)
    assert_not sa.active?, 'service account should be deactivatable'
  end

  private

  def create_service_account(attrs = {})
    defaults = {
      authentik_id: "sa-#{SecureRandom.hex(4)}",
      full_name: "Service Account #{SecureRandom.hex(4)}",
      payment_type: 'unknown',
      service_account: true,
      active: true
    }
    User.create!(defaults.merge(attrs))
  end
end
