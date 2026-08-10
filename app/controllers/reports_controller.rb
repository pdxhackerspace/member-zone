class ReportsController < AuthenticatedController
  include Pagy::Method

  PER_PAGE = 25

  before_action -> { require_privilege!(:'reports.view') }, only: %i[index show charts]
  before_action -> { require_privilege!(:'reports.edit_users') }, only: :update_user

  # load_report first: the sidebar counts skip whichever report is on screen, because
  # showing it works that number out anyway.
  before_action :load_report, only: :show
  before_action :load_counts, only: %i[index show charts]

  # Landing page: every report as a card, grouped by category, with live counts.
  def index
    @grouped = Reports::Catalog.grouped
    @attention = Reports::Catalog.reports.select { |report| report.attention? && @counts[report.key].to_i.positive? }
  end

  # A single report. Only this report's rows are loaded, and only once — each
  # build_query returns a fresh object, so its memoized work would start over.
  def show
    query = @report.build_query
    @pagy, @rows = pagy(query.relation, limit: PER_PAGE)
    @locals = @report.locals.merge(query.page_locals(@rows))
    @counts[@report.key] = @pagy.count
  end

  def charts
    @charts = Reports::ChartData.new.call
  end

  def update_user
    user = User.find(params[:user_id])
    key = params[:anchor].presence || 'membership-status-unknown'
    notice = apply_user_action(user, params[:action_type], key)

    return redirect_to reports_path, alert: 'Invalid action.' if notice.nil?

    redirect_to report_path(key), notice: notice
  end

  private

  def load_counts
    @counts = Reports::Catalog.counts(except: @report&.key)
  end

  def load_report
    @report = Reports::Catalog.find(params[:key])
    redirect_to reports_path, alert: 'Unknown report.' if @report.nil?
  end

  # Returns the flash notice, or nil when the action is not recognised.
  def apply_user_action(user, action_type, key)
    case action_type
    when 'activate', 'deactivate' then toggle_active(user, action_type)
    when 'ban' then apply_transition(user, :ban!, 'banned')
    when 'deceased' then apply_transition(user, :mark_deceased!, 'deceased')
    when 'paying' then apply_transition(user, :record_payment!, 'a current member')
    when 'sponsored', 'guest' then set_status_or_payment_type(user, action_type, key)
    when 'cash', 'paypal', 'recharge' then set_payment_type(user, action_type)
    when 'payment_guest' then set_payment_type(user, 'guest')
    when 'payment_sponsored' then set_payment_type(user, 'sponsored')
    end
  end

  def toggle_active(user, action_type)
    unless user.service_account?
      return "Active status for #{user.display_name} is determined by membership and dues status."
    end

    active = action_type == 'activate'
    user.update!(active: active)
    "#{user.display_name} #{active ? 'activated' : 'deactivated'}."
  end

  # Membership changes go through the state machine on User rather than assigning
  # status columns, which are projections and would be overwritten on save.
  def apply_transition(user, method, description)
    return "#{user.display_name} could not be marked #{description}." unless user.public_send(method)

    "#{user.display_name} marked #{description}."
  end

  def set_payment_type(user, type)
    user.update!(payment_type: type)
    "#{user.display_name} payment type set to #{type}."
  end

  # On the payment-type report these buttons mean payment type; everywhere else they
  # mean membership state.
  def set_status_or_payment_type(user, value, key)
    return set_payment_type(user, value) if key == 'payment-type-unknown'
    return apply_transition(user, :mark_sponsored!, 'sponsored') if value == 'sponsored'

    apply_transition(user, :mark_guest!, 'a guest')
  end
end
