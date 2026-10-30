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

  test 'index filter tiles keep the search query' do
    get cash_payments_path(q: 'zzz')
    assert_response :success

    assert_select 'a[href*="period=month"][href*="q=zzz"]'
  end

  test 'shows index' do
    get cash_payments_path
    assert_response :success
    assert_select 'h1', /Cash payments/i
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

    # Far enough back that the overdue grace period has run out too, so the member lands in
    # inactive rather than part-way along.
    patch cash_payment_path(payment), params: {
      cash_payment: {
        paid_on: 4.months.ago.to_date
      }
    }

    assert_redirected_to cash_payment_path(payment)
    @user.reload
    assert_equal 4.months.ago.to_date, @user.last_payment_date
    assert_equal 4.months.ago.to_date + @plan.billing_period_days.days, @user.dues_due_at.to_date
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

  test 'destroying last cash payment clears dates for cancelled members' do
    @user.cash_payments.destroy_all
    payment = CashPayment.create!(user: @user, membership_plan: @plan, amount: 100, paid_on: 10.days.ago.to_date,
                                  recorded_by: users(:one))
    @user.update_columns(membership_state: 'cancelled_member', payment_type: 'cash',
                         membership_cancelled_at: 5.days.ago)

    delete cash_payment_path(payment)

    @user.reload
    assert_nil @user.last_payment_date
    assert_nil @user.dues_due_at
    assert_equal 'cancelled_member', @user.membership_state
  end

  test 'a cash payment after a cancellation brings the member back' do
    @user.cash_payments.destroy_all
    @user.update_columns(membership_state: 'cancelled_member', membership_cancelled_at: 3.days.ago,
                         membership_state_entered_at: 3.days.ago)

    post_cash_payment

    @user.reload
    assert_equal 'current_member', @user.membership_state
    assert_nil @user.membership_cancelled_at
  end

  # Cash carries only a date, so a payment on the day they cancelled is taken as coming back.
  test 'a cash payment dated on the cancellation day brings the member back' do
    @user.cash_payments.destroy_all
    cancelled_at = Time.current.end_of_day - 1.hour
    @user.update_columns(membership_state: 'cancelled_member', membership_cancelled_at: cancelled_at,
                         membership_state_entered_at: cancelled_at)

    post_cash_payment(paid_on: cancelled_at.to_date)

    assert_equal 'current_member', @user.reload.membership_state
  end

  test 'a cash payment dated before the cancellation leaves the member cancelled' do
    @user.cash_payments.destroy_all
    @user.update_columns(membership_state: 'cancelled_member', membership_cancelled_at: Time.current,
                         membership_state_entered_at: Time.current, dues_due_at: 20.days.from_now)

    post_cash_payment(paid_on: 1.day.ago.to_date)

    @user.reload
    assert_equal 'cancelled_member', @user.membership_state
    assert_equal 1.day.ago.to_date, @user.last_payment_date
  end

  test 'deletes cash payment and recalculates membership' do
    @user.cash_payments.destroy_all
    post_cash_payment

    payment = CashPayment.last
    event = payment.payment_events.first
    assert_equal Date.current, @user.reload.last_payment_date

    assert_difference('CashPayment.count', -1) do
      assert_difference('PaymentEvent.count', -1) do
        delete cash_payment_path(payment)
      end
    end

    @user.reload
    assert_nil @user.last_payment_date
    assert_nil @user.dues_due_at
    assert_equal 'inactive_member', @user.membership_state
    assert_not PaymentEvent.exists?(event.id)
  end

  test 'editing an old cash payment does not revive an inactive member' do
    @user.cash_payments.destroy_all
    paid_on = Date.new(2026, 9, 27)
    payment = CashPayment.create!(
      user: @user,
      membership_plan: @plan,
      amount: 40,
      paid_on: paid_on,
      notes: 'Old',
      recorded_by: users(:one)
    )
    ended = Date.new(2026, 10, 27)
    @user.update_columns(
      membership_state: 'inactive_member',
      membership_state_entered_at: Time.zone.local(2026, 10, 27),
      membership_ended_date: ended,
      last_payment_date: paid_on
    )

    patch cash_payment_path(payment), params: {
      cash_payment: { notes: 'Corrected note', paid_on: paid_on, amount: 40 }
    }

    assert_redirected_to cash_payment_path(payment)
    @user.reload
    assert_equal 'inactive_member', @user.membership_state
    assert_equal ended, @user.membership_ended_date
  end

  test 'a cash payment dated on the state entry day revives an overdue member' do
    @user.cash_payments.destroy_all
    paid_on = Date.new(2026, 10, 28)
    @user.update_columns(
      membership_state: 'overdue_member',
      membership_state_entered_at: Time.zone.local(2026, 10, 28),
      dues_due_at: Time.zone.local(2026, 10, 28)
    )

    post_cash_payment(paid_on: paid_on)

    assert_redirected_to cash_payment_path(CashPayment.last)
    @user.reload
    assert_equal 'current_member', @user.membership_state
    assert_operator @user.dues_due_at.to_date, :>, paid_on
  end

  test 'a cash payment dated after state entry revives an inactive member' do
    @user.cash_payments.destroy_all
    payment = CashPayment.create!(
      user: @user,
      membership_plan: @plan,
      amount: 40,
      paid_on: Date.new(2026, 9, 27),
      recorded_by: users(:one)
    )
    @user.update_columns(
      membership_state: 'inactive_member',
      membership_state_entered_at: Time.zone.local(2026, 10, 27),
      membership_ended_date: Date.new(2026, 10, 27)
    )

    patch cash_payment_path(payment), params: {
      cash_payment: { paid_on: Date.new(2026, 10, 28), amount: 40 }
    }

    assert_redirected_to cash_payment_path(payment)
    @user.reload
    assert_equal 'current_member', @user.membership_state
    assert_nil @user.membership_ended_date
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
