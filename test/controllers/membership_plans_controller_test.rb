require 'test_helper'

class MembershipPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    sign_in_as_local_admin
    @user = users(:cash_payer)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'mark_dues_received sets dues_due_at from plan billing cycle' do
    @user.update_columns(dues_due_at: nil, membership_state: 'overdue_member', dues_status: 'lapsed',
                         last_payment_date: 2.months.ago.to_date)
    assert_difference('CashPayment.count', 1) do
      post mark_dues_received_membership_plans_path, params: { user_id: @user.id }
    end
    assert_redirected_to manual_payments_membership_plans_path
    @user.reload
    assert_equal 'current', @user.dues_status
    assert_equal Date.current + @user.membership_plan.billing_period_days.days, @user.dues_due_at.to_date
    payment = @user.cash_payments.order(:created_at).last
    assert_equal @user.membership_plan.cost, payment.amount
    assert payment.payment_events.exists?(event_type: 'payment')
  end

  # Marking dues received is a payment like any other, so it follows the same rule.
  test 'mark_dues_received cannot undo a cancellation dated after the payment' do
    @user.update_columns(membership_state: 'cancelled_member', membership_cancelled_at: 1.day.from_now,
                         membership_state_entered_at: Time.current, dues_due_at: 20.days.from_now)

    post mark_dues_received_membership_plans_path, params: { user_id: @user.id }

    assert_equal 'cancelled_member', @user.reload.membership_state
  end

  test 'personal plan edit form uses billing period days field' do
    plan = membership_plans(:personal_equipment_donation)

    get edit_membership_plan_path(plan)

    assert_response :success
    assert_select 'input[name=?][value=?]', 'membership_plan[billing_period_days]', plan.billing_period_days.to_s
    assert_select '.input-group-text', text: 'Days'
    assert_select 'select[name=?]', 'membership_plan[billing_frequency]', count: 0
  end

  test 'creates personal plan with billing period days' do
    assert_difference('MembershipPlan.personal.count', 1) do
      post membership_plans_path, params: {
        membership_plan: {
          user_id: users(:one).id,
          name: 'Custom Days Plan',
          cost: '75.00',
          billing_period_days: '45',
          plan_type: 'primary',
          display_order: '1'
        }
      }
    end

    assert_redirected_to membership_plans_path(anchor: 'personal-plans')
    plan = MembershipPlan.find_by!(name: 'Custom Days Plan')
    assert_equal 45, plan.billing_period_days
    assert_equal 'custom_days', plan.billing_frequency
  end

  test 'updates personal plan billing period days' do
    plan = membership_plans(:personal_equipment_donation)

    patch membership_plan_path(plan), params: {
      membership_plan: {
        billing_period_days: '45'
      }
    }

    assert_redirected_to membership_plans_path
    assert_equal 45, plan.reload.billing_period_days
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
