class MembershipPlansController < AuthenticatedController
  # Any signed-in member can look at a shared plan on offer; hidden and personal plans need
  # either plans.view_hidden or membership of the plan itself.
  # No `new` here: the controller has no such action, and the route is gone (see routes.rb).
  # Listing it would raise AbstractController::ActionNotFound rather than protect anything.
  before_action -> { require_privilege!(:'plans.manage') }, only: %i[index edit create update destroy]
  before_action -> { require_privilege!(:'plans.manual_payments') }, only: %i[manual_payments mark_dues_received]
  before_action :set_membership_plan, only: %i[show edit update destroy]
  before_action :require_plan_readable!, only: %i[show]

  def index
    @membership_plans = MembershipPlan.shared.ordered.includes(:users)
    @personal_plans = MembershipPlan.personal.includes(:user).order(:name)
    @membership_plan = MembershipPlan.new
    @personal_plan = MembershipPlan.new
  end

  def show
    other_plans = MembershipPlan.shared.where.not(id: @membership_plan.id).ordered
    other_plans = other_plans.visible unless can?(:'plans.view_hidden')
    @other_plans = other_plans
  end

  def edit; end

  def create
    @membership_plan = MembershipPlan.new(membership_plan_params)

    if @membership_plan.user_id.present?
      # Personal plan creation
      if @membership_plan.save
        redirect_to membership_plans_path(anchor: 'personal-plans'),
                    notice: "Personal plan created for #{@membership_plan.user.display_name}."
      else
        @membership_plans = MembershipPlan.shared.ordered.includes(:users)
        @personal_plans = MembershipPlan.personal.includes(:user).order(:name)
        @personal_plan = @membership_plan
        @membership_plan = MembershipPlan.new
        render :index, status: :unprocessable_content
      end
    elsif @membership_plan.save
      # Shared plan creation
      redirect_to membership_plans_path, notice: 'Membership plan created successfully.'
    else
      @membership_plans = MembershipPlan.shared.ordered.includes(:users)
      @personal_plans = MembershipPlan.personal.includes(:user).order(:name)
      @personal_plan = MembershipPlan.new
      render :index, status: :unprocessable_content
    end
  end

  def update
    if @membership_plan.update(membership_plan_params)
      redirect_to membership_plans_path, notice: 'Membership plan updated successfully.'
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    if @membership_plan.personal?
      if @membership_plan.cash_payments.any?
        redirect_to membership_plans_path(anchor: 'personal-plans'),
                    alert: 'Cannot delete personal plan that has cash payments recorded against it.'
      else
        @membership_plan.destroy
        redirect_to membership_plans_path(anchor: 'personal-plans'), notice: 'Personal plan deleted.'
      end
    else
      has_users = @membership_plan.primary? ? @membership_plan.users.any? : @membership_plan.supplementary_users.any?
      if has_users
        redirect_to membership_plans_path,
                    alert: 'Cannot delete membership plan that has members assigned to it.'
      else
        @membership_plan.destroy
        redirect_to membership_plans_path, notice: 'Membership plan deleted successfully.'
      end
    end
  end

  def manual_payments
    manual_plans = MembershipPlan.manual.ordered
    @members = []

    due_soon_cutoff_date = Date.current + MembershipSetting.manual_payment_due_soon_days

    manual_plans.each do |plan|
      users = plan.primary? ? plan.users : plan.supplementary_users
      users.includes(:membership_plan).find_each do |user|
        next_date = user.next_payment_date
        @members << {
          user: user,
          plan: plan,
          next_payment_date: next_date,
          near_due: next_date.present? && next_date <= due_soon_cutoff_date
        }
      end
    end

    # Sort: near-due first, then by next payment date (soonest first), then name
    @members.sort_by! do |m|
      [
        m[:near_due] ? 0 : 1,
        m[:next_payment_date] || Date.new(9999, 1, 1),
        m[:user].display_name.downcase
      ]
    end
  end

  def mark_dues_received
    user = User.find(params[:user_id])
    old_dues_status = user.dues_status
    dues_at = User.dues_due_at_from_payment_cycle(Date.current, user.membership_plan)
    user.record_payment!(last_payment_date: Date.current, dues_due_at: dues_at)
    Journal.create!(
      user: user,
      actor_user: current_user,
      action: 'membership_status_changed',
      changed_at: Time.current,
      changes_json: { 'dues_status' => { 'from' => old_dues_status, 'to' => 'current' },
                      'note' => 'Manual dues received' }
    )
    redirect_to manual_payments_membership_plans_path, notice: "Marked dues received for #{user.display_name}."
  end

  private

  def set_membership_plan
    @membership_plan = MembershipPlan.find(params[:id])
  end

  # Hidden plans are not browsable by id, and neither are personal plans, which the model
  # always forces hidden. A member may still open a plan they are actually on, so a
  # grandfathered plan withdrawn from signup stays reachable from the member's own profile.
  def require_plan_readable!
    return if can?(:'plans.view_hidden')
    return if @membership_plan.visible? && !@membership_plan.personal?
    return if member_on_plan?(@membership_plan)

    redirect_to root_path, alert: 'That membership plan is not available.'
  end

  def member_on_plan?(plan)
    return false unless current_user

    plan.user_id == current_user.id || current_user.has_plan?(plan)
  end

  def membership_plan_params
    params.expect(membership_plan: %i[name cost billing_frequency billing_period_days description payment_link plan_type
                                      paypal_transaction_subject manual visible display_order user_id])
  end
end
