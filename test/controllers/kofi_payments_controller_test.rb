require 'test_helper'

class KofiPaymentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_local_admin
    @payment = KofiPayment.create!(
      kofi_transaction_id: 'KOFI-PRIVACY-1',
      status: 'completed',
      amount: 25.00,
      currency: 'USD',
      timestamp: Time.zone.local(2026, 5, 1, 12, 0, 0),
      payment_type: 'Donation',
      from_name: 'Privacy Supporter',
      email: 'kofi-private@example.com',
      message: 'Thanks for the space',
      raw_attributes: {
        'Email' => 'kofi-private@example.com',
        'Ko-fi Transaction ID' => 'KOFI-PRIVACY-1'
      },
      last_synced_at: Time.current
    )
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'index filter tiles keep the search query' do
    get kofi_payments_path(q: 'zzz')
    assert_response :success

    assert_select 'a[href*="linked=no"][href*="q=zzz"]'
  end

  test 'index does not show supporter email addresses' do
    get kofi_payments_path

    assert_response :success
    assert_select 'h1', text: 'Ko-fi payments'
    assert_match @payment.kofi_transaction_id, response.body
    assert_no_match(/kofi-private@example\.com/, response.body)
    assert_select 'a[href^=?]', 'mailto:', count: 0
  end

  test 'show masks supporter email and raw data with reveal control' do
    get kofi_payment_path(@payment)

    assert_response :success
    assert_select '[data-controller=?]', 'sensitive-reveal'
    assert_select '[data-action=?]', 'click->sensitive-reveal#toggle', text: /Show contact details/
    assert_select '[data-sensitive-reveal-target=?]', 'blurred', text: /kofi-private@example\.com/
    assert_select 'pre[data-sensitive-reveal-target=?]', 'blurred', text: /Ko-fi Transaction ID/
  end

  private

  def sign_in_as_local_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: {
        email: account.email,
        password: 'localpassword123'
      }
    }
  end
end
