require 'test_helper'
require 'active_job/test_helper'

class PaypalPaymentsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_local_admin
    @payment = paypal_payments(:sample_payment)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'shows index' do
    get paypal_payments_path
    assert_response :success
    assert_select 'h1', /PayPal payments/i
    assert_match @payment.paypal_id, response.body
  end

  # The default list is the payments matching a plan. When every payment has a subject no plan
  # claims, the page says so and offers the unmatched view, rather than claiming nothing synced.
  test 'empty matched list points at the subjects waiting for a plan' do
    PaypalPayment.update_all(matches_plan: false)

    get paypal_payments_path

    assert_response :success
    assert_select 'turbo-frame#paypal_payments_results', text: /No PayPal payment matches a membership plan yet/
    assert_select 'a[href=?]', paypal_payments_path(show_unmatched: 'true'), text: 'View unmatched subjects'
  end

  test 'empty list with nothing synced at all says so' do
    PaypalPayment.delete_all

    get paypal_payments_path

    assert_response :success
    assert_select 'turbo-frame#paypal_payments_results', text: /No PayPal payments have been synced yet/
  end

  test 'shows payment' do
    get paypal_payment_path(@payment)
    assert_response :success
    assert_match @payment.paypal_id, response.body
  end

  test 'show masks payer email and raw data with reveal control' do
    get paypal_payment_path(@payment)

    assert_response :success
    assert_select '[data-controller=?]', 'sensitive-reveal'
    assert_select '[data-action=?]', 'click->sensitive-reveal#toggle', text: /Show contact details/
    assert_select '[data-sensitive-reveal-target=?]', 'blurred', text: /donor@example\.com/
    assert_select 'pre[data-sensitive-reveal-target=?]', 'blurred', text: /transaction_info/
  end

  test 'enqueues sync job' do
    assert_enqueued_with(job: Paypal::PaymentSyncJob) do
      post sync_paypal_payments_path
    end
    assert_redirected_to paypal_payments_path
  end

  test 'live search is rendered as server search without retaining pagination' do
    get paypal_payments_path(page: 2, q: 'pagination target')

    assert_response :success
    assert_select 'form[action=?][method=get][data-turbo-frame=?]', paypal_payments_path, 'paypal_payments_results' do
      assert_select 'input[name=q][value=?]', 'pagination target'
      assert_select 'input[name=page]', count: 0
    end
    assert_select 'turbo-frame[id=?]', 'paypal_payments_results'
  end

  test 'payment result links navigate outside turbo search frame' do
    payment = PaypalPayment.create!(
      paypal_id: 'PAY-FRAME-TARGET',
      status: 'COMPLETED',
      amount: 42.50,
      currency: 'USD',
      transaction_time: Time.current,
      transaction_type: 'T0001',
      payer_email: 'paypal-frame@example.com',
      payer_name: 'PayPal Frame Target',
      payer_id: 'PAYER-FRAME-TARGET',
      matches_plan: true
    )

    get paypal_payments_path(q: 'PAY-FRAME-TARGET')
    assert_response :success

    assert_select 'turbo-frame#paypal_payments_results a[href=?][data-turbo-frame=?]',
                  paypal_payment_path(payment), '_top'
  end

  test 'index shows linked member in payer column without separate linked member column' do
    get paypal_payments_path(q: @payment.paypal_id)

    assert_response :success
    assert_select 'th', text: 'Linked Member', count: 0
    assert_select 'td.paypal-payment-payer a[href=?][data-turbo-frame=?]',
                  user_path(@payment.user), '_top',
                  text: @payment.user.display_name
  end

  # An unlinked payment shows the name PayPal gave us and the way to link it, never the payer's
  # email address: that is encrypted at rest, and the detail page is where it gets revealed.
  test 'index shows the payer name and a link affordance when a payment is unlinked' do
    payment = PaypalPayment.create!(
      paypal_id: 'PAY-UNLINKED-PAYER',
      status: 'COMPLETED',
      amount: 42.50,
      currency: 'USD',
      transaction_time: Time.current,
      transaction_type: 'T0001',
      payer_email: 'unlinked-payer@example.com',
      payer_name: 'Unlinked Payer',
      payer_id: 'PAYER-UNLINKED-PAYER',
      matches_plan: true
    )

    get paypal_payments_path(q: payment.paypal_id)

    assert_response :success
    assert_select 'td.paypal-payment-payer', text: /Unlinked Payer/
    assert_no_match(/unlinked-payer@example\.com/, response.body)
    assert_select 'td.paypal-payment-payer a[href=?]', paypal_payment_path(payment), text: 'Link member…'
  end

  test 'payment search paginates the filtered result set' do
    105.times do |index|
      PaypalPayment.create!(
        paypal_id: "PAY-PAGE-FILLER-#{index}",
        status: 'COMPLETED',
        amount: 42.50,
        currency: 'USD',
        transaction_time: Time.current - index.minutes,
        transaction_type: 'T0001',
        payer_email: "paypal-filler-#{index}@example.com",
        payer_name: "PayPal Filler #{index}",
        payer_id: "PAYER-FILLER-#{index}",
        matches_plan: true
      )
    end
    target = PaypalPayment.create!(
      paypal_id: 'PAY-LIVE-SEARCH-TARGET',
      status: 'COMPLETED',
      amount: 42.50,
      currency: 'USD',
      transaction_time: 1.year.ago,
      transaction_type: 'T0001',
      payer_email: 'paypal-live-search-target@example.com',
      payer_name: 'PayPal Live Search Pagination Target',
      payer_id: 'PAYER-LIVE-SEARCH-TARGET',
      matches_plan: true
    )

    get paypal_payments_path
    assert_response :success
    assert_no_match target.paypal_id, response.body

    get paypal_payments_path(q: 'Live Search Pagination Target')
    assert_response :success
    assert_match target.paypal_id, response.body
  end

  test 'link_user links the payment and returns to it' do
    payment = PaypalPayment.create!(paypal_id: 'PAY-LINK-1', payer_id: 'PAYER-LINK-1', amount: 25,
                                    transaction_time: Time.current)
    user = users(:two)

    post link_user_paypal_payment_path(payment), params: { user_id: user.id }

    assert_redirected_to paypal_payment_path(payment)
    assert_equal user.id, payment.reload.user_id
    assert_equal 'PAYER-LINK-1', user.reload.paypal_account_id
  end

  test 'link_user reports payments it cannot link and returns to them' do
    payment = PaypalPayment.create!(paypal_id: 'PAY-LINK-2', payer_id: nil, amount: 25,
                                    transaction_time: Time.current)

    post link_user_paypal_payment_path(payment), params: { user_id: users(:two).id }

    assert_redirected_to paypal_payment_path(payment)
    assert_equal 'Cannot link: payment has no payer ID.', flash[:alert]
    assert_nil payment.reload.user_id
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
