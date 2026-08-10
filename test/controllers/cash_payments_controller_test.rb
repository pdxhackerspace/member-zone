require 'test_helper'

class CashPaymentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_local_admin
    @payment = cash_payments(:sample_cash_payment)
    @user = users(:cash_payer)
    @plan = membership_plans(:personal_equipment_donation)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'shows index' do
    get cash_payments_path
    assert_response :success
    assert_select 'h1', /Cash Payments/
  end

  test 'shows payment' do
    get cash_payment_path(@payment)
    assert_response :success
    assert_match @payment.identifier, response.body
  end

  test 'shows new form' do
    get new_cash_payment_path
    assert_response :success
    assert_select 'h1', /Record Cash Payment/
  end

  test 'shows new form with user_id prepopulated' do
    get new_cash_payment_path(user_id: @user.id)
    assert_response :success
  end

  test 'creates cash payment and updates user dues' do
    assert_difference('CashPayment.count', 1) do
      post cash_payments_path, params: {
        cash_payment: {
          user_id: @user.id,
          membership_plan_id: @plan.id,
          amount: 100.00,
          paid_on: Date.current,
          notes: 'Test payment'
        }
      }
    end
    assert_redirected_to cash_payment_path(CashPayment.last)

    @user.reload
    assert_equal 'current', @user.dues_status
    assert_equal 'cash', @user.payment_type
    assert @user.dues_due_at.present?
    assert_equal Date.current + @plan.billing_period_days.days, @user.dues_due_at.to_date
  end

  test 'create sets payment due date when none is recorded' do
    @user.update_columns(dues_due_at: nil, last_payment_date: nil)

    post_cash_payment

    assert_redirected_to cash_payment_path(CashPayment.last)
    @user.reload
    assert_equal Date.current + @plan.billing_period_days.days, @user.dues_due_at.to_date
  end

  test 'create advances payment due date when calculated date is later' do
    @user.update_columns(dues_due_at: 1.week.from_now, last_payment_date: nil)

    post_cash_payment

    assert_redirected_to cash_payment_path(CashPayment.last)
    @user.reload
    assert_equal Date.current + @plan.billing_period_days.days, @user.dues_due_at.to_date
  end

  test 'create does not move payment due date earlier' do
    existing_due_at = 2.months.from_now.beginning_of_day
    @user.update_columns(dues_due_at: existing_due_at, last_payment_date: nil)

    post_cash_payment

    assert_redirected_to cash_payment_path(CashPayment.last)
    @user.reload
    assert_equal existing_due_at.to_date, @user.dues_due_at.to_date
  end

  test 'create sets payment due date from the personal plan not the primary membership plan' do
    monthly = membership_plans(:monthly_standard)
    personal_plan = MembershipPlan.create!(
      name: "Semi-annual #{SecureRandom.hex(4)}",
      cost: 200.00,
      billing_frequency: 'custom_days',
      billing_period_days: 180,
      plan_type: 'primary',
      user: @user
    )
    @user.update_columns(
      membership_plan_id: monthly.id,
      dues_due_at: nil,
      last_payment_date: nil
    )

    post cash_payments_path, params: {
      cash_payment: {
        user_id: @user.id,
        membership_plan_id: personal_plan.id,
        amount: 200.00,
        paid_on: Date.current
      }
    }

    assert_redirected_to cash_payment_path(CashPayment.last)
    @user.reload
    assert_equal monthly.id, @user.membership_plan_id
    assert_equal Date.current + 180.days, @user.dues_due_at.to_date
  end

  test 'create rejects invalid data' do
    assert_no_difference('CashPayment.count') do
      post cash_payments_path, params: {
        cash_payment: {
          user_id: @user.id,
          membership_plan_id: @plan.id,
          amount: 0,
          paid_on: Date.current
        }
      }
    end
    assert_response :unprocessable_content
  end

  test 'create rejects shared plan' do
    shared_plan = membership_plans(:monthly_standard)
    assert_no_difference('CashPayment.count') do
      post cash_payments_path, params: {
        cash_payment: {
          user_id: @user.id,
          membership_plan_id: shared_plan.id,
          amount: 50.00,
          paid_on: Date.current
        }
      }
    end
    assert_response :unprocessable_content
  end

  test 'shows edit form' do
    get edit_cash_payment_path(@payment)
    assert_response :success
    assert_select 'h1', /Edit Cash Payment/
  end

  test 'updates cash payment' do
    patch cash_payment_path(@payment), params: {
      cash_payment: {
        amount: 150.00,
        notes: 'Updated notes'
      }
    }
    assert_redirected_to cash_payment_path(@payment)
    @payment.reload
    assert_equal 150.00, @payment.amount.to_f
    assert_equal 'Updated notes', @payment.notes
  end

  test 'updating cash payment recalculates overdue dues and active status' do
    @user.cash_payments.destroy_all
    payment = CashPayment.create!(
      user: @user,
      membership_plan: @plan,
      amount: 100.00,
      paid_on: Date.current,
      recorded_by: users(:one)
    )
    @user.update!(
      membership_state: 'current_member',
      active: true,
      payment_type: 'cash',
      dues_due_at: 1.month.from_now
    )

    patch cash_payment_path(payment), params: {
      cash_payment: {
        paid_on: 2.months.ago.to_date
      }
    }

    assert_redirected_to cash_payment_path(payment)
    @user.reload
    assert_equal 2.months.ago.to_date, @user.last_payment_date
    assert_equal 2.months.ago.to_date + @plan.billing_period_days.days, @user.dues_due_at.to_date
    assert_equal 'lapsed', @user.dues_status
    assert_not @user.active?
  end

  test 'updating older cash payment keeps dues based on latest paid date' do
    @user.cash_payments.destroy_all
    latest_paid_on = 3.days.ago.to_date
    CashPayment.create!(
      user: @user,
      membership_plan: @plan,
      amount: 100.00,
      paid_on: latest_paid_on,
      recorded_by: users(:one)
    )
    older_payment = CashPayment.create!(
      user: @user,
      membership_plan: @plan,
      amount: 100.00,
      paid_on: 3.months.ago.to_date,
      recorded_by: users(:one)
    )

    patch cash_payment_path(older_payment), params: {
      cash_payment: {
        notes: 'Edited older payment'
      }
    }

    assert_redirected_to cash_payment_path(older_payment)
    @user.reload
    assert_equal latest_paid_on, @user.last_payment_date
    assert_equal latest_paid_on + @plan.billing_period_days.days, @user.dues_due_at.to_date
    assert_equal 'current', @user.dues_status
    assert @user.active?
  end

  test 'updating cash payment syncs payment event date and amount' do
    @user.cash_payments.destroy_all
    post_cash_payment
    payment = CashPayment.last
    event = payment.payment_events.first

    patch cash_payment_path(payment), params: {
      cash_payment: {
        amount: 125.50,
        paid_on: 10.days.ago.to_date
      }
    }

    assert_redirected_to cash_payment_path(payment)
    event.reload
    assert_equal 125.50, event.amount.to_f
    assert_equal 10.days.ago.to_date, event.occurred_at.to_date
  end

  test 'deletes cash payment' do
    assert_difference('CashPayment.count', -1) do
      delete cash_payment_path(@payment)
    end
    assert_redirected_to cash_payments_path
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

  def post_cash_payment(paid_on: Date.current)
    post cash_payments_path, params: {
      cash_payment: {
        user_id: @user.id,
        membership_plan_id: @plan.id,
        amount: 100.00,
        paid_on: paid_on,
        notes: 'Test payment'
      }
    }
  end
end
