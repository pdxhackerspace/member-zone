class CashPaymentsController < AuthenticatedController
  include Pagy::Method

  # Recording cash is its own privilege because it moves a member's dues status directly,
  # with no processor to reconcile against. Reading the ledger is not: a billing coordinator
  # reconciling a month needs every payment in it, cash included.
  before_action -> { require_any_privilege!(:'payments.view', :'payments.manage_cash') }, only: %i[index show]
  before_action -> { require_privilege!(:'payments.manage_cash') }, only: %i[new create edit update destroy]

  before_action :set_cash_payment, only: %i[show edit update destroy]

  def index
    @cash_payments = CashPayment.includes(:user, :membership_plan, :recorded_by).ordered
    @pagy, @cash_payments = pagy(@cash_payments, limit: 25)
  end

  def show; end

  def new
    @cash_payment = CashPayment.new(paid_on: Date.current)
    @cash_payment.user_id = params[:user_id] if params[:user_id].present?

    return if @cash_payment.user_id.blank?

    user = User.find(@cash_payment.user_id)
    personal_plans = user.personal_membership_plans
    @cash_payment.membership_plan_id = personal_plans.first&.id if personal_plans.one?
  end

  def edit; end

  def create
    @cash_payment = CashPayment.new(cash_payment_params)
    @cash_payment.recorded_by = current_user

    if @cash_payment.save
      sync_payment_event(@cash_payment)
      update_user_dues_status(@cash_payment)
      redirect_to cash_payment_path(@cash_payment),
                  notice: "Cash payment recorded for #{@cash_payment.user.display_name}."
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    original_user = @cash_payment.user

    if @cash_payment.update(cash_payment_params)
      sync_payment_event(@cash_payment)
      recalculate_user_cash_dues!(original_user) if original_user != @cash_payment.user
      recalculate_user_cash_dues!(@cash_payment.user)
      redirect_to cash_payment_path(@cash_payment), notice: 'Cash payment updated.'
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    user = @cash_payment.user
    user_name = user.display_name
    @cash_payment.destroy
    recalculate_user_cash_dues!(user)
    redirect_to cash_payments_path, notice: "Cash payment for #{user_name} deleted."
  end

  private

  def set_cash_payment
    @cash_payment = CashPayment.find(params[:id])
  end

  def cash_payment_params
    params.expect(cash_payment: %i[user_id membership_plan_id amount paid_on notes])
  end

  def update_user_dues_status(cash_payment)
    user = cash_payment.user
    old_dues_status = user.dues_status
    current_dues_due_at = user.dues_due_at

    updates = user.apply_payment_updates(
      { time: cash_payment.paid_on.beginning_of_day, amount: cash_payment.amount },
      { payment_type: 'cash', last_payment_date: cash_payment.paid_on },
      billing_plan: cash_payment.membership_plan
    )
    keep_later_dues_due_at!(updates, current_dues_due_at)

    user.update!(updates) if updates.present?

    Journal.create!(
      user: user,
      actor_user: current_user,
      action: 'membership_status_changed',
      changed_at: Time.current,
      changes_json: {
        'dues_status' => { 'from' => old_dues_status, 'to' => 'current' },
        'note' => "Cash payment of $#{format('%.2f', cash_payment.amount)} recorded"
      }
    )
  end

  def sync_payment_event(cash_payment)
    event = cash_payment.payment_events.find_or_initialize_by(
      source: 'cash',
      external_id: cash_payment.identifier,
      event_type: 'payment'
    )
    event.assign_attributes(
      user: cash_payment.user,
      amount: cash_payment.amount,
      currency: 'USD',
      occurred_at: cash_payment.paid_on&.beginning_of_day || Time.current,
      details: "Cash payment - #{cash_payment.membership_plan&.name || 'Unknown plan'}"
    )
    event.save!
  end

  def recalculate_user_cash_dues!(user)
    latest_payment = user.cash_payments.order(paid_on: :desc, created_at: :desc).first
    if latest_payment.blank?
      recalculate_user_without_cash_payments!(user)
      return
    end

    due_at = User.dues_due_at_from_payment_cycle(latest_payment.paid_on, latest_payment.membership_plan)
    apply_cash_payment_membership_update!(user, paid_on: latest_payment.paid_on, due_at: due_at)
  end

  def recalculate_user_without_cash_payments!(user)
    return if user.membership_state.in?(User::PAYMENT_IMMUNE_STATES)

    last_paid = latest_payment_date_from_sources(user)
    if last_paid.blank?
      user.update!(last_payment_date: nil, dues_due_at: nil)
      user.transition_to!('inactive_member') unless user.membership_state.in?(User::PAYMENT_IMMUNE_STATES)
      return
    end

    attrs = { last_payment_date: last_paid }
    if last_paid.present? && user.membership_plan.present?
      attrs[:dues_due_at] = User.dues_due_at_from_payment_cycle(last_paid, user.membership_plan)
    else
      attrs[:dues_due_at] = nil
    end

    user.update!(attrs)
    user.expire_membership_state! if user.membership_state_expired?
  end

  def latest_payment_date_from_sources(user)
    [
      user.paypal_payments.maximum(:transaction_time),
      user.recharge_payments.maximum(:processed_at),
      user.cash_payments.maximum(:paid_on)
    ].compact.map(&:to_date).max
  end

  def apply_cash_payment_membership_update!(user, paid_on:, due_at:)
    unless user.membership_state.in?(User::PAYMENT_IMMUNE_STATES)
      user.record_payment!(
        payment_type: 'cash',
        last_payment_date: paid_on,
        dues_due_at: due_at
      )
      user.update!(membership_ended_date: nil) if user.membership_ended_date.present?
      return
    end

    user.update!(
      payment_type: 'cash',
      last_payment_date: paid_on,
      dues_due_at: due_at
    )
  end

  def keep_later_dues_due_at!(updates, current_dues_due_at)
    return unless updates.key?(:dues_due_at)

    new_dues_due_at = updates[:dues_due_at]
    if new_dues_due_at.blank?
      updates.delete(:dues_due_at)
      return
    end

    return if current_dues_due_at.blank?
    return if new_dues_due_at > current_dues_due_at

    updates.delete(:dues_due_at)
  end
end
