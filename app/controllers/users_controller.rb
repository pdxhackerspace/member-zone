class UsersController < AuthenticatedController
  include TrainingHistoryData
  include ParkingStatusFiltering

  helper_method :viewing_own_profile?

  skip_before_action :require_authenticated_user!, only: [:show]
  before_action :set_user_for_show, only: [:show]
  before_action :set_user,
                only: %i[edit update activate deactivate
                         enable_emergency_active_override clear_emergency_active_override
                         ban unban mark_deceased record_cancellation mark_sponsored
                         unmark_sponsored destroy
                         sync_to_authentik sync_from_authentik
                         unlink_slack unlink_authentik unlink_sheet
                         mark_help_seen pause_key_access resume_key_access]
  # The bulk Authentik operations have no catalog key of their own, so they stay with
  # administrators: `sync` and `sync_all_to_authentik` push every member to the identity
  # provider and `toggle_authentik_sync_inactive_as_active` changes how they are pushed.
  before_action :require_admin!, only: %i[sync sync_all_to_authentik toggle_authentik_sync_inactive_as_active]
  before_action -> { require_privilege!(:'members.view_list') }, only: :index
  before_action -> { require_privilege!(:'members.create') }, only: %i[new create]
  before_action -> { require_privilege!(:'members.toggle_active') }, only: %i[activate deactivate]
  before_action -> { require_privilege!(:'members.emergency_active_override') },
                only: %i[enable_emergency_active_override clear_emergency_active_override]
  before_action -> { require_privilege!(:'members.ban') }, only: %i[ban unban]
  before_action -> { require_privilege!(:'members.mark_deceased') }, only: :mark_deceased
  before_action -> { require_privilege!(:'members.edit_membership') }, only: :record_cancellation
  before_action -> { require_privilege!(:'members.sponsor') }, only: %i[mark_sponsored unmark_sponsored]
  before_action -> { require_privilege!(:'members.delete') }, only: :destroy
  before_action -> { require_privilege!(:'members.sync_authentik') },
                only: %i[sync_to_authentik sync_from_authentik]
  before_action -> { require_privilege!(:'members.unlink_sources') },
                only: %i[unlink_slack unlink_authentik unlink_sheet]
  before_action -> { require_privilege!(:'access.pause_resume') }, only: %i[pause_key_access resume_key_access]
  before_action :authorize_profile_view, only: [:show]
  before_action :authorize_self_or_admin, only: %i[edit update]

  # email is absent deliberately: the column holds ciphertext, so ordering by it returns
  # rows in an order unrelated to the addresses shown.
  SORTABLE_COLUMNS = %w[username full_name membership_state membership_status payment_type last_synced_at].freeze

  def index
    # Start with all users for the "all" count
    all_users = User.all
    @all_user_count = all_users.count

    # Legacy count (from all users)
    @legacy_count = all_users.legacy.count

    # Include legacy members when checkbox is checked
    @include_legacy = params[:include_legacy] == '1'
    default_users = @include_legacy ? all_users : all_users.non_legacy

    # Build the base filter params hash (used for stacking links)
    @filter_params = {}
    @filter_params[:include_legacy] = '1' if @include_legacy
    @filter_params[:membership_state] = params[:membership_state] if params[:membership_state].present?
    @filter_params[:membership_status] = params[:membership_status] if params[:membership_status].present?
    @filter_params[:payment_type] = params[:payment_type] if params[:payment_type].present?
    @filter_params[:dues_status] = params[:dues_status] if params[:dues_status].present?
    @filter_params[:active] = params[:active] if params[:active].present?
    @filter_params[:membership_plan_id] = params[:membership_plan_id] if params[:membership_plan_id].present?
    @filter_params[:missing] = params[:missing] if params[:missing].present?
    @filter_params[:account_type] = params[:account_type] if params[:account_type].present?
    @filter_params[:key_access] = params[:key_access] if params[:key_access].present?
    if params[:emergency_active_override].present?
      @filter_params[:emergency_active_override] = params[:emergency_active_override]
    end
    @filter_params[:q] = params[:q] if params[:q].present?
    @filter_params[:sort] = params[:sort] if params[:sort].present?
    @filter_params[:direction] = params[:direction] if params[:direction].present?

    # Build filtered query by applying all active filters
    @users = default_users

    if params[:q].present?
      search_term = "%#{params[:q].downcase}%"
      # Encrypted email cannot be matched by substring; a whole address still resolves
      # through the lookup digest.
      @users = @users.where(
        "LOWER(COALESCE(full_name, '')) LIKE :p " \
        'OR LOWER(authentik_id) LIKE :p ' \
        "OR LOWER(COALESCE(username, '')) LIKE :p",
        p: search_term
      ).or(default_users.merge(User.by_any_email(params[:q])))
    end

    if params[:membership_state].present?
      @users = @users.non_service_accounts.where(membership_state: params[:membership_state])
    end
    if params[:membership_status].present?
      @users = @users.non_service_accounts.where(membership_status: params[:membership_status])
    end
    @users = @users.non_service_accounts.where(payment_type: params[:payment_type]) if params[:payment_type].present?
    @users = @users.non_service_accounts.where(dues_status: params[:dues_status]) if params[:dues_status].present?
    if params[:membership_plan_id].present?
      @users = if params[:membership_plan_id] == 'none'
                 @users.non_service_accounts.where(membership_plan_id: nil)
               else
                 @users.non_service_accounts.where(membership_plan_id: params[:membership_plan_id])
               end
    end
    @users = @users.where(active: params[:active] == 'true') if params[:active].present?

    if params[:account_type] == 'service'
      @users = @users.service_accounts
    elsif params[:account_type] == 'member'
      @users = @users.non_service_accounts
    end

    if params[:emergency_active_override] == '1'
      @users = @users.non_service_accounts.where(emergency_active_override: true)
    end

    if params[:missing] == 'rfid'
      @users = @users.non_service_accounts.where.missing(:rfids)
    elsif params[:missing] == 'email'
      @users = @users.non_service_accounts.where("email IS NULL OR email = ''")
    end

    @users = @users.non_service_accounts.where(key_access_paused: true) if params[:key_access] == 'paused'

    # Total count always from the full (non-legacy-adjusted) set for the "X of Y" message
    @user_count = default_users.count

    # Active/inactive counts from the filtered set
    @active_count = @users.where(active: true).count
    @inactive_count = @users.where(active: false).count

    # Badge counts from the filtered set so they reflect stacked filters
    filtered_members = @users.non_service_accounts

    @membership_state_counts = filtered_members.group(:membership_state).count

    @payment_type_unknown = filtered_members.where(payment_type: 'unknown').count
    @payment_type_sponsored = filtered_members.where(payment_type: 'sponsored').count
    @payment_type_paypal = filtered_members.where(payment_type: 'paypal').count
    @payment_type_recharge = filtered_members.where(payment_type: 'recharge').count
    @payment_type_cash = filtered_members.where(payment_type: 'cash').count

    @membership_plans = MembershipPlan.ordered.to_a
    @plan_counts = @membership_plans.map { |plan| [plan, filtered_members.where(membership_plan_id: plan.id).count] }
    @no_plan_count = filtered_members.where(membership_plan_id: nil)
                                     .where.not(membership_status: %w[guest sponsored])
                                     .where(is_sponsored: false)
                                     .count

    @no_rfid_count = filtered_members.where.missing(:rfids).count
    @no_email_count = filtered_members.where("email IS NULL OR email = ''").count
    @key_paused_count = filtered_members.where(key_access_paused: true).count

    @service_account_count = @users.service_accounts.count
    @member_account_count = @users.non_service_accounts.count
    @emergency_active_override_count = all_users.non_service_accounts.where(emergency_active_override: true).count

    # Apply sorting — use Arel nodes to avoid string interpolation (CodeQL SQL injection rule)
    @sort_column = SORTABLE_COLUMNS.include?(params[:sort]) ? params[:sort] : 'full_name'
    @sort_direction = %w[asc desc].include?(params[:direction]) ? params[:direction] : 'asc'
    col_node = User.arel_table[@sort_column]
    direction_node = @sort_direction == 'desc' ? col_node.desc : col_node.asc
    @users = @users.order(Arel::Nodes::NullsLast.new(direction_node))

    # Track if any filter is active (including legacy toggle)
    @filter_active = params[:membership_state].present? || params[:membership_status].present? ||
                     params[:payment_type].present? ||
                     params[:dues_status].present? || params[:active].present? ||
                     params[:missing].present? || params[:account_type].present? ||
                     params[:membership_plan_id].present? || params[:q].present? ||
                     params[:emergency_active_override].present? || params[:key_access].present?
    @filtered_count = @users.count if @filter_active || @include_legacy

    # Store filter/sort params for passing to user profile links
    @list_params = @filter_params.dup

    @recent_members = User.non_service_accounts.non_legacy
                          .where(created_at: 1.week.ago..)
                          .ordered_by_display_name

    @pagy, @users = pagy(@users, limit: 100)
  end

  def show
    # Determine view level based on viewer and profile settings
    @natural_view_level = determine_view_level
    @view_level = determine_effective_view_level
    @profile_hidden = profile_hidden_for_view?(@view_level)
    @profile_caps = profile_capabilities

    # Set up view preview options for admins and profile owners
    setup_view_preview_options

    # Default tab
    requested_tab = params[:tab]&.to_sym
    @active_tab = if requested_tab.present?
                    requested_tab
                  elsif @view_level == :self
                    :dashboard
                  else
                    :profile
                  end

    # Parking notices for admin and self views. The self view gets stacking
    # status filter pills (default: active only); the admin view keeps the
    # uncleared list.
    if @view_level == :admin || @view_level == :self
      parking_base = @user.parking_notices
      @parking_notices_count = parking_base.not_cleared.count
      if @view_level == :self
        @parking_status_counts = parking_base.group(:status).count
        @parking_selected_statuses = selected_parking_statuses
        @parking_notices_list = apply_parking_status_filter(parking_base).newest_first.limit(50)
      else
        @parking_notices_list = parking_base.not_cleared.newest_first.limit(50)
      end
    end

    # Messages for admin and self views (not deleted by the recipient)
    if @view_level == :admin || @view_level == :self
      messages_query = @user.received_messages
                            .not_deleted_by_recipient
                            .includes(:sender)
                            .newest_first
      @messages_count = messages_query.count
      @unread_messages_count = @user.received_messages.not_deleted_by_recipient.unread.count
      @pagy_messages, @messages = pagy(messages_query, limit: 20, page_key: 'messages_page')
    end

    if @view_level == :self
      set_self_service_training_data
      set_member_dashboard_data
      load_completed_training_requests(@user)
      load_training_history(@user) if @active_tab == :training_history
    end

    # Payment history follows the same rule as Journal, Access and Mail: self always sees their
    # own; in the admin layout it loads only when payments.view reveals the tab. Holders of
    # members.view_profile reach the admin layout on their own profile too, so check ownership
    # separately from @view_level.
    if @view_level == :self || (@view_level == :admin && (viewing_own_profile? || @profile_caps[:view_payments]))
      @payment_event_filter = params[:event_type].presence
      payments_query = PaymentHistory.for_user(@user, event_type: @payment_event_filter)
      @payments_count = payments_query.count
      @pagy_payments, @payments = pagy(payments_query, limit: 20, page_key: 'payments_page')
    end

    # Each of these backs one tab, so it loads on the same capability that reveals the tab.
    # Loading them together behind a single admin check would either leave a holder's tab
    # empty or make everyone pay for queries they cannot see.
    if @view_level == :admin
      if @profile_caps[:view_journal]
        journals_query = @user.journals.includes(:actor_user).order(changed_at: :desc, created_at: :desc)
        @journals_count = journals_query.count
        @pagy_journals, @journals = pagy(journals_query, limit: 20, page_key: 'journal_page')
      end

      if @profile_caps[:view_access_logs]
        access_query = @user.access_logs.order(logged_at: :desc)
        @access_count = access_query.count
        @most_recent_access = access_query.first
        @pagy_accesses, @recent_accesses = pagy(access_query, limit: 20, page_key: 'access_page')
      end

      if @profile_caps[:view_incidents]
        incidents_query = @user.incident_reports.includes(:reporter).ordered
        @incidents_count = incidents_query.count
        @pagy_incidents, @user_incidents = pagy(incidents_query, limit: 20, page_key: 'incidents_page')
      end

      if @profile_caps[:view_mail]
        mail_query = @user.queued_mails.includes(:email_template, :reviewed_by, :mail_log_entries).newest_first
        @mail_count = mail_query.count
        @pagy_mails, @queued_mails = pagy(mail_query, limit: 20, page_key: 'mail_page')
      end
    end

    if current_user_admin?
      # Find previous and next users for navigation (always for admin toolbar)
      # Rebuild the same filtered/sorted query from the index page
      nav_query = User.all

      # Apply filters if present
      nav_query = nav_query.where(membership_state: params[:membership_state]) if params[:membership_state].present?
      nav_query = nav_query.where(membership_status: params[:membership_status]) if params[:membership_status].present?
      nav_query = nav_query.where(payment_type: params[:payment_type]) if params[:payment_type].present?
      nav_query = nav_query.where(dues_status: params[:dues_status]) if params[:dues_status].present?
      nav_query = nav_query.where(active: params[:active] == 'true') if params[:active].present?
      if params[:emergency_active_override] == '1'
        nav_query = nav_query.where(service_account: false, emergency_active_override: true)
      end
      nav_query = nav_query.where(service_account: false, key_access_paused: true) if params[:key_access] == 'paused'

      # Apply sorting — use Arel nodes to avoid string interpolation (CodeQL SQL injection rule)
      sort_column = SORTABLE_COLUMNS.include?(params[:sort]) ? params[:sort] : 'full_name'
      sort_direction = %w[asc desc].include?(params[:direction]) ? params[:direction] : 'asc'
      nav_col_node = User.arel_table[sort_column]
      nav_direction_node = sort_direction == 'desc' ? nav_col_node.desc : nav_col_node.asc
      nav_query = nav_query.order(Arel::Nodes::NullsLast.new(nav_direction_node))

      ordered_ids = nav_query.pluck(:id)
      current_index = ordered_ids.index(@user.id)

      if current_index
        @previous_user = current_index.positive? ? User.find(ordered_ids[current_index - 1]) : nil
        @next_user = current_index < ordered_ids.length - 1 ? User.find(ordered_ids[current_index + 1]) : nil
      else
        @previous_user = nil
        @next_user = nil
      end

      # Store filter/sort params for use in view links
      @nav_params = {}
      @nav_params[:membership_state] = params[:membership_state] if params[:membership_state].present?
      @nav_params[:membership_status] = params[:membership_status] if params[:membership_status].present?
      @nav_params[:payment_type] = params[:payment_type] if params[:payment_type].present?
      @nav_params[:dues_status] = params[:dues_status] if params[:dues_status].present?
      @nav_params[:active] = params[:active] if params[:active].present?
      if params[:emergency_active_override].present?
        @nav_params[:emergency_active_override] = params[:emergency_active_override]
      end
      @nav_params[:key_access] = params[:key_access] if params[:key_access].present?
      @nav_params[:sort] = params[:sort] if params[:sort].present?
      @nav_params[:direction] = params[:direction] if params[:direction].present?
    end

    # Member help - show to users viewing their own profile
    # Use true_user to ensure impersonation doesn't trigger the help for the admin
    @member_help_content = TextFragment.content_for('member_help')
    @show_member_help_auto = false

    return unless @member_help_content.present? && true_user && true_user.id == @user.id && !impersonating?

    # Show automatically on first view (use true_user to not affect impersonated users)
    @show_member_help_auto = !true_user.seen_member_help
  end

  def new
    @user = User.new
  end

  def edit
    return unless !current_user_admin? && @user == current_user

    redirect_to profile_setup_path
    nil
  end

  def create
    @user = User.new(resolved_user_params)

    if @user.save
      redirect_to user_path(@user), notice: 'Member created successfully.'
    else
      if @user.errors.of_kind?(:email, :taken)
        existing_user = find_existing_user_by_email(@user.email)
        flash.now[:alert] = if existing_user
                              helpers.safe_join(
                                [
                                  'Unable to create member: email is already in use by ',
                                  helpers.link_to(existing_user.display_name, user_path(existing_user)),
                                  '.'
                                ]
                              )
                            else
                              'Unable to create member: email is already in use.'
                            end
      else
        flash.now[:alert] = 'Unable to create member.'
      end
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @user.update(resolved_user_params)
      redirect_to user_path(@user), notice: 'Member updated successfully.'
    else
      flash.now[:alert] = 'Unable to update user.'
      render :edit, status: :unprocessable_content
    end
  end

  def sync
    unless MemberSource.enabled?('authentik')
      redirect_to users_path, alert: 'Authentik source is disabled.'
      return
    end

    Authentik::GroupSyncJob.perform_later
    redirect_to users_path, notice: 'Authentik group sync has been scheduled.'
  end

  def sync_all_to_authentik
    unless MemberSource.enabled?('member_zone')
      redirect_to users_path, alert: 'Member Zone source is disabled.'
      return
    end

    Authentik::FullSyncToAuthentikJob.perform_later
    redirect_to users_path,
                notice: 'Full sync to Authentik has been scheduled. ' \
                        'All members, application groups, and the active members group will be synced.'
  end

  def toggle_authentik_sync_inactive_as_active
    settings = DefaultSetting.instance
    settings.update!(authentik_sync_inactive_as_active: !settings.authentik_sync_inactive_as_active)

    # Inactive members that already exist in Authentik aren't normally re-synced
    # because their authentik_dirty flag was cleared after their last sync. Toggling
    # this setting changes what their Authentik is_active value should be, so flag them
    # dirty and run a sync to reconcile Authentik with the new setting.
    affected = User.where(active: false).where.not(authentik_id: [nil, '']).update_all(authentik_dirty: true)
    Authentik::FullSyncToAuthentikJob.perform_later if MemberSource.enabled?('member_zone')

    status = settings.authentik_sync_inactive_as_active? ? 'active' : 'inactive'
    redirect_to users_path,
                notice: "Inactive members will now be synced as #{status} in Authentik. " \
                        "Syncing #{affected} inactive #{'member'.pluralize(affected)} now."
  end

  def activate
    unless @user.service_account?
      redirect_to user_path(@user),
                  alert: 'Active status for non-service accounts is determined by membership and dues status.'
      return
    end
    @user.update!(active: true)
    redirect_to user_path(@user), notice: 'Account activated.'
  end

  def deactivate
    unless @user.service_account?
      redirect_to user_path(@user),
                  alert: 'Active status for non-service accounts is determined by membership and dues status.'
      return
    end
    @user.update!(active: false)
    redirect_to user_path(@user), notice: 'Account deactivated.'
  end

  def pause_key_access
    if @user.key_access_paused?
      redirect_to key_access_redirect_path, notice: "Key access is already paused for #{@user.display_name}."
      return
    end

    @user.pause_key_access!
    redirect_to key_access_redirect_path,
                notice: "Key access paused for #{@user.display_name}. " \
                        'Their keys are kept but will not be synced to the access controllers.'
  end

  def resume_key_access
    unless @user.key_access_paused?
      redirect_to key_access_redirect_path, notice: "Key access is not paused for #{@user.display_name}."
      return
    end

    @user.resume_key_access!
    redirect_to key_access_redirect_path,
                notice: "Key access resumed for #{@user.display_name}. " \
                        'Sync the access controllers to restore their access.'
  end

  def enable_emergency_active_override
    if @user.service_account?
      redirect_to user_path(@user), alert: 'Service accounts use Activate / Deactivate instead.'
      return
    end
    if @user.terminal_membership_state?
      redirect_to user_path(@user), alert: 'Active override is not available for banned or deceased members.'
      return
    end
    if @user.emergency_active_override?
      redirect_to user_path(@user), notice: 'Active override is already enabled.'
      return
    end
    if @user.active?
      redirect_to user_path(@user), alert: 'Member is already active.'
      return
    end

    @user.update!(emergency_active_override: true)
    redirect_to user_path(@user),
                notice: 'Active override enabled. They stay active until you clear the override.'
  end

  def clear_emergency_active_override
    unless @user.emergency_active_override?
      redirect_to user_path(@user), alert: 'Active override is not enabled.'
      return
    end

    @user.update!(emergency_active_override: false)
    redirect_to user_path(@user),
                notice: 'Active override cleared; active status was recalculated from membership.'
  end

  # The ban email is queued by the state machine and held for review before it is sent.
  def ban
    @user.ban!
    redirect_to user_path(@user), notice: 'Member banned.'
  end

  def unban
    unless @user.banned?
      redirect_to user_path(@user), alert: 'Member is not banned.'
      return
    end

    @user.unban!
    recalculated = @user.membership_state.humanize.downcase
    redirect_to user_path(@user), notice: "Ban lifted; membership recalculated as #{recalculated}."
  end

  def mark_deceased
    @user.mark_deceased!
    redirect_to user_path(@user), notice: 'Member marked as deceased.'
  end

  # Recorded when we learn a member cancelled outside a provider we get webhooks from.
  # They keep access until their paid-through date.
  def record_cancellation
    unless @user.record_cancellation!
      redirect_to user_path(@user), alert: 'Cancellation cannot be recorded for this member.'
      return
    end

    redirect_to user_path(@user), notice: 'Cancellation recorded. Access continues until their paid-through date.'
  end

  def mark_sponsored
    @user.mark_sponsored!
    QueuedMail.enqueue(:membership_sponsored, @user, reason: 'Membership sponsored') if @user.email.present?
    redirect_to user_path(@user), notice: 'Member marked as sponsored.'
  end

  def unmark_sponsored
    @user.unmark_sponsored!
    redirect_to user_path(@user), notice: 'Member sponsorship removed.'
  end

  def destroy
    @user.destroy!
    redirect_to users_path, notice: 'Member deleted successfully.'
  end

  def sync_to_authentik
    unless MemberSource.enabled?('member_zone')
      redirect_to user_path(@user), alert: 'Member Zone source is disabled.'
      return
    end

    if @user.authentik_id.blank?
      redirect_to user_path(@user), alert: 'Member does not have an Authentik ID.'
      return
    end

    sync = Authentik::UserSync.new(@user)
    result = sync.sync_to_authentik!

    case result[:status]
    when 'synced'
      redirect_to user_path(@user), notice: 'Member synced to Authentik successfully.'
    when 'skipped'
      redirect_to user_path(@user), notice: "Sync skipped: #{result[:reason]}"
    when 'error'
      redirect_to user_path(@user), alert: "Sync failed: #{result[:error]}"
    end
  end

  def sync_from_authentik
    unless MemberSource.enabled?('authentik')
      redirect_to user_path(@user), alert: 'Authentik source is disabled.'
      return
    end

    if @user.authentik_id.blank?
      redirect_to user_path(@user), alert: 'Member does not have an Authentik ID.'
      return
    end

    # Prevent sync loop
    Current.skip_authentik_sync = true
    sync = Authentik::UserSync.new(@user)
    result = sync.sync_from_authentik!
    Current.skip_authentik_sync = false

    case result[:status]
    when 'updated'
      redirect_to user_path(@user), notice: "Member updated from Authentik: #{result[:changes].join(', ')}"
    when 'no_changes'
      redirect_to user_path(@user), notice: 'No changes from Authentik.'
    when 'error'
      redirect_to user_path(@user), alert: "Sync failed: #{result[:error]}"
    end
  end

  def unlink_slack
    slack_user = @user.slack_user
    if slack_user.blank? && @user.slack_id.blank? && @user.slack_handle.blank?
      redirect_to user_path(@user, tab: :profile), alert: 'Member is not linked to a Slack account.'
      return
    end

    SlackUser.transaction do
      slack_user&.update!(user_id: nil)
      clear_user_slack_fields!(@user, slack_user)
    end

    MemberSource.for('slack').refresh_statistics!
    redirect_to user_path(@user, tab: :profile), notice: 'Slack account disassociated from member.'
  end

  def unlink_authentik
    authentik_user = @user.authentik_user || AuthentikUser.find_by(authentik_id: @user.authentik_id)
    if authentik_user.blank? && @user.authentik_id.blank?
      redirect_to user_path(@user, tab: :profile), alert: 'Member is not linked to an Authentik account.'
      return
    end

    AuthentikUser.transaction do
      authentik_user&.update!(user_id: nil)
      @user.update_columns(authentik_id: nil, authentik_dirty: false, updated_at: Time.current)
    end

    MemberSource.for('authentik').refresh_statistics!
    redirect_to user_path(@user, tab: :profile), notice: 'Authentik account disassociated from member.'
  end

  def unlink_sheet
    sheet_entry = @user.sheet_entry
    if sheet_entry.blank?
      redirect_to user_path(@user, tab: :profile), alert: 'Member is not linked to a sheet entry.'
      return
    end

    sheet_entry.update!(user_id: nil)
    MemberSource.for('sheet').refresh_statistics!
    redirect_to user_path(@user, tab: :profile), notice: 'Sheet entry disassociated from member.'
  end

  # Mark member help as seen (only for the user themselves)
  def mark_help_seen
    # Use true_user to ensure impersonation doesn't mark the impersonated user's help as seen
    if true_user && true_user.id == @user.id
      true_user.update_column(:seen_member_help, true)
      head :ok
    else
      head :forbidden
    end
  end

  private

  # Pause/resume can be triggered from the member profile or the Add Key Fob screen.
  # Return to the originating screen so the toggled button stays in context.
  def key_access_redirect_path
    if params[:return_to] == 'add_key'
      new_rfid_path(rfid: { user_id: @user.id })
    else
      user_path(@user, tab: :profile)
    end
  end

  def set_user_for_show
    @user = User.includes(
      :sheet_entry, :slack_user, :rfids, :user_links, :membership_applications,
      trainings_as_trainee: :training_topic, training_topics: []
    ).find_by_param(params[:id])
  end

  def set_user
    @user = User.find_by_param(params[:id])
  end

  def clear_user_slack_fields!(user, slack_user)
    updates = { updated_at: Time.current }
    if slack_user.present?
      updates[:slack_id] = nil if user.slack_id == slack_user.slack_id
      updates[:slack_handle] = nil if user.slack_id == slack_user.slack_id || user.slack_handle == slack_user.username
    else
      updates[:slack_id] = nil
      updates[:slack_handle] = nil
    end

    user.update_columns(updates) if updates.keys != [:updated_at]
  end

  def authorize_self_or_admin
    return if current_user_admin?
    return if @user == current_user
    # Editing someone else's profile is the whole point of these privileges; which fields
    # actually save is decided per attribute in #user_params.
    return if can?(:'members.edit_membership') || can?(:'members.edit_profile') || can?(:'members.edit_notes')

    redirect_to user_path(current_user), alert: 'You may only edit your own profile.'
  end

  def authorize_profile_view
    return if current_user_admin? || can?(:'members.view_profile')

    # Users can see their own profile
    return if user_signed_in? && @user == current_user

    # Check profile visibility settings
    # Anyone can view a public profile. For members-only and private profiles,
    # only anonymous visitors are redirected to sign in. Signed-in members fall
    # through to the show action, which renders the profile or, for a private
    # profile, a "this profile is private" notice at the same URL.
    return if @user.profile_visibility == 'public'

    redirect_to login_path, alert: 'Please sign in to view this profile.' unless user_signed_in?
  end

  # Whether the profile body should be replaced with a "not available" notice
  # for the given view level, based on the profile's visibility setting.
  # Admin and self view levels always see the full profile.
  def viewing_own_profile?
    user_signed_in? && @user == current_user
  end

  def profile_hidden_for_view?(view_level)
    case @user.profile_visibility
    when 'members'
      view_level == :public
    when 'private'
      view_level.in?(%i[public members])
    else
      false
    end
  end

  # What the viewer may do on this profile, declared once so the page and its partials read
  # one set instead of repeating privilege checks.
  #
  # @view_level answers a different question — how much of the profile its *owner* has
  # chosen to expose, and which preview an administrator has selected. It stays. This
  # answers what the viewer is entitled to act on, which a single :admin flag could not
  # express: a Front desk greeter and an administrator both reach the admin layout and
  # should not see the same buttons.
  #
  # Preview honours it too: an administrator viewing as :self or :members holds nothing
  # here, so the preview shows what that member would really get.
  def profile_capabilities
    return Hash.new(false) unless @view_level == :admin

    {
      edit_profile: can?(:'members.edit_profile'),
      edit_membership: can?(:'members.edit_membership'),
      edit_notes: can?(:'members.edit_notes'),
      view_private_contact: can?(:'members.view_private_contact'),
      toggle_active: can?(:'members.toggle_active'),
      emergency_override: can?(:'members.emergency_active_override'),
      ban: can?(:'members.ban'),
      mark_deceased: can?(:'members.mark_deceased'),
      sponsor: can?(:'members.sponsor'),
      delete: can?(:'members.delete'),
      grant_admin: can?(:'members.grant_admin'),
      impersonate: current_user_admin?,
      send_message: can?(:'members.send_message'),
      sync_authentik: can?(:'members.sync_authentik'),
      unlink_sources: can?(:'members.unlink_sources'),
      view_rfids: can?(:'access.view_rfids'),
      manage_rfids: can?(:'access.manage_rfids'),
      pause_access: can?(:'access.pause_resume'),
      view_access_logs: can?(:'access.view_logs'),
      view_payments: can?(:'payments.view'),
      view_journal: can?(:'journal.view'),
      view_mail: can?(:'queued_mail.view'),
      view_incidents: can?(:'incidents.manage'),
      view_parking: can?(:'parking.manage_notices'),
      record_training: can_for_any_topic?(:'training.record'),
      grant_trainer: can?(:'training.grant_trainer')
    }
  end

  def determine_view_level
    # :admin - full access to everything
    # :self - user viewing their own profile (same as members view + edit)
    # :members - logged in member viewing another member's profile
    # :public - not logged in viewing a public profile

    # members.view_profile reaches the same layout as an administrator, but the regions
    # inside it are gated one by one — a holder gets identity and the Profile tab, not the
    # kebab, the modals, or the Journal, Mail and Payments tabs.
    return :admin if current_user_admin? || can?(:'members.view_profile')
    return :self if user_signed_in? && @user == current_user
    return :members if user_signed_in?

    :public
  end

  def determine_effective_view_level
    # Check if user is requesting a specific view level via params
    requested_view = params[:view_as]&.to_sym
    requested_view = :members if requested_view == :other

    return @natural_view_level if requested_view.blank?

    # Validate that the user can access the requested view level
    allowed_views = allowed_preview_views
    return @natural_view_level unless allowed_views.include?(requested_view)

    requested_view
  end

  def allowed_preview_views
    # Admins can preview all views
    return %i[public members self admin] if current_user_admin?

    # Profile owners can preview public, members, and self views
    return %i[public members self] if user_signed_in? && @user == current_user

    # Others cannot preview
    []
  end

  def setup_view_preview_options
    # Don't show preview selector when impersonating - show exact user view
    @can_preview_views = !impersonating? && allowed_preview_views.length > 1
    view_labels = {
      admin: 'Admin',
      self: 'The member',
      members: 'Other members',
      public: 'Public'
    }.freeze
    @available_views = allowed_preview_views.map { |level| [view_labels[level], level] }
  end

  def set_self_service_training_data
    @member_requestable_topics = TrainingTopic.available_for_member_requests

    trainer_topic_ids = current_user.training_topics.select(:id)
    ordering = 'training_topics.name ASC, training_requests.created_at DESC'
    @trainer_training_requests_by_topic = TrainingRequest.pending
                                                         .where(training_topic_id: trainer_topic_ids)
                                                         .joins(:training_topic)
                                                         .includes(:training_topic, :user)
                                                         .order(ordering)
                                                         .group_by(&:training_topic)
  end

  def set_member_dashboard_data
    @member_dashboard_attention_items = []
    @member_dashboard_ok_items = []

    append_member_dashboard_payment_item
    append_member_dashboard_messages_item
    append_member_dashboard_training_item
    append_member_dashboard_slack_item
    append_member_dashboard_parking_item
  end

  def append_member_dashboard_messages_item
    unread_count = Message.folder(@user, :unread).count
    if unread_count.positive?
      add_member_dashboard_item(
        ok: false,
        id: :unread_messages,
        tier: :urgent,
        title: 'Unread messages',
        detail: "You have #{unread_count} unread message#{'s' unless unread_count == 1}.",
        action_label: 'Open Messages',
        action_path: messages_path(folder: :unread)
      )
      return
    end

    add_member_dashboard_item(
      ok: true,
      id: :unread_messages,
      tier: :none,
      title: 'Unread messages',
      detail: 'You have no unread messages.'
    )
  end

  def append_member_dashboard_payment_item
    unless member_manual_payment?
      add_member_dashboard_item(
        ok: true,
        id: :cash_payment_due,
        tier: :none,
        title: 'Cash payment due',
        detail: 'You are not on a manual/cash payment plan.'
      )
      return
    end

    due_on = @user.next_payment_date
    if due_on.blank?
      add_member_dashboard_item(
        ok: false,
        id: :cash_payment_due,
        tier: :housekeeping,
        title: 'Cash payment due',
        detail: 'No next payment due date is recorded yet. Please contact an admin.',
        action_label: 'View payment history',
        action_path: user_path(@user, tab: :payments, view_as: params[:view_as])
      )
      return
    end

    days_until = (due_on - Date.current).to_i
    if days_until.negative?
      add_member_dashboard_item(
        ok: false,
        id: :cash_payment_due,
        tier: :urgent,
        title: 'Cash payment due',
        detail: "Your next cash payment was due #{due_on.strftime('%B %-d, %Y')} (#{days_until.abs} days overdue).",
        action_label: 'View payment history',
        action_path: user_path(@user, tab: :payments, view_as: params[:view_as])
      )
      return
    end

    due_soon_days = MembershipSetting.manual_payment_due_soon_days
    if days_until <= due_soon_days
      add_member_dashboard_item(
        ok: false,
        id: :cash_payment_due,
        tier: :important,
        title: 'Cash payment due soon',
        detail: "Your next cash payment is due in #{days_until} days (#{due_on.strftime('%B %-d, %Y')}).",
        action_label: 'View payment history',
        action_path: user_path(@user, tab: :payments, view_as: params[:view_as])
      )
      return
    end

    add_member_dashboard_item(
      ok: true,
      id: :cash_payment_due,
      tier: :none,
      title: 'Cash payment due',
      detail: "Your next cash payment is due in #{days_until} days (#{due_on.strftime('%B %-d, %Y')})."
    )
  end

  def append_member_dashboard_training_item
    pending_count = @user.training_requests.pending.count
    if pending_count.positive?
      add_member_dashboard_item(
        ok: false,
        id: :training_requests,
        tier: :important,
        title: 'Open training requests',
        detail: "You have #{pending_count} open training request#{'s' unless pending_count == 1}.",
        action_label: 'Open Profile tab',
        action_path: user_path(@user, tab: :profile, view_as: params[:view_as])
      )
      return
    end

    add_member_dashboard_item(
      ok: true,
      id: :training_requests,
      tier: :none,
      title: 'Open training requests',
      detail: 'You have no open training requests.'
    )
  end

  def append_member_dashboard_slack_item
    if @user.slack_user.present?
      add_member_dashboard_item(
        ok: true,
        id: :slack_signup,
        tier: :none,
        title: 'Slack account',
        detail: 'Your account is linked to Slack.'
      )
      return
    end

    if SlackOidcConfig.configured?
      add_member_dashboard_item(
        ok: false,
        id: :slack_signup,
        tier: :housekeeping,
        title: 'Slack account',
        detail: 'Link your CTRLH Slack workspace member to your profile so we can recognize you on Slack.',
        action_label: 'Associate Slack account',
        action_path: slack_link_start_path
      )
    else
      add_member_dashboard_item(
        ok: false,
        id: :slack_signup,
        tier: :housekeeping,
        title: 'Join Slack',
        detail: 'You do not have a linked Slack user yet. Please ask an admin for an invite.',
        action_label: 'View Profile',
        action_path: user_path(@user, tab: :profile, view_as: params[:view_as])
      )
    end
  end

  def append_member_dashboard_parking_item
    notices = @user.parking_notices.not_cleared
    expired_count = notices.expired_notices.count
    active_count = notices.active_notices.count
    open_count = expired_count + active_count

    if expired_count.positive?
      detail = "#{expired_count} expired and #{active_count} active open parking notice#{'s' unless open_count == 1}."
      add_member_dashboard_item(
        ok: false,
        id: :parking_notices,
        tier: :urgent,
        title: 'Open parking permits/tickets',
        detail: detail,
        action_label: 'Open Parking tab',
        action_path: user_path(@user, tab: :parking, view_as: params[:view_as])
      )
      return
    end

    if active_count.positive?
      add_member_dashboard_item(
        ok: false,
        id: :parking_notices,
        tier: :important,
        title: 'Open parking permits/tickets',
        detail: "#{active_count} active open parking notice#{'s' unless active_count == 1}.",
        action_label: 'Open Parking tab',
        action_path: user_path(@user, tab: :parking, view_as: params[:view_as])
      )
      return
    end

    add_member_dashboard_item(
      ok: true,
      id: :parking_notices,
      tier: :none,
      title: 'Open parking permits/tickets',
      detail: 'You have no open parking permits or tickets.'
    )
  end

  def member_manual_payment?
    return true if @user.payment_type == 'cash'

    @user.all_membership_plans.any?(&:manual?)
  end

  def add_member_dashboard_item(item)
    if item[:ok]
      @member_dashboard_ok_items << item
    else
      @member_dashboard_attention_items << item
    end
  end

  def user_params
    permitted = %i[
      username full_name email pronouns profile_visibility bio greeting_name greeting_option
      use_full_name_for_greeting use_username_for_greeting do_not_greet
    ]

    # Split per attribute rather than per action: update is shared with self-service
    # editing, so the fields are what carry the authority. Keep this in step with
    # app/views/users/_form.html.erb, or the form offers inputs that are then dropped.
    if can?(:'members.edit_membership')
      permitted += %i[membership_state payment_type membership_plan_id dues_due_at
                      sponsored_guest_duration_months]
    end

    permitted += %i[aliases_text mailing_address phone_number] if can?(:'members.edit_profile')
    permitted << :notes if can?(:'members.edit_notes')
    permitted << :is_admin if can?(:'members.grant_admin')
    permitted += %i[service_account legacy] if current_user_admin?
    # Only allow manual active toggle for service accounts
    permitted << :active if @user&.service_account? && can?(:'members.toggle_active')

    params.require(:user).permit(permitted)
  end

  def resolved_user_params
    attrs = user_params.to_h.symbolize_keys
    apply_greeting_option!(attrs)
    filter_restricted_membership_state!(attrs)
    # An admin editing the form is making a deliberate correction, so it is allowed to
    # cross the transition table the automated paths are held to.
    attrs[:allow_any_membership_state_transition] = true if attrs.key?(:membership_state)
    attrs
  end

  # Banned and deceased states require their dedicated privileges and flows.
  def filter_restricted_membership_state!(attrs)
    return unless attrs.key?(:membership_state)

    new_state = attrs[:membership_state].to_s
    current = @user&.membership_state.to_s

    restricted_targets = []
    restricted_targets << 'banned_member' unless can?(:'members.ban')
    restricted_targets << 'deceased_member' unless can?(:'members.mark_deceased')

    if restricted_targets.include?(new_state)
      attrs.delete(:membership_state)
      return
    end

    locked = (current == 'banned_member' && !can?(:'members.ban')) ||
             (current == 'deceased_member' && !can?(:'members.mark_deceased'))
    attrs.delete(:membership_state) if locked && new_state != current
  end

  def apply_greeting_option!(attrs)
    option = attrs.delete(:greeting_option)
    return if option.blank?

    case option
    when 'full_name'
      attrs[:use_full_name_for_greeting] = true
      attrs[:use_username_for_greeting]  = false
      attrs[:do_not_greet]               = false
      attrs.delete(:greeting_name)
    when 'username'
      attrs[:use_full_name_for_greeting] = false
      attrs[:use_username_for_greeting]  = true
      attrs[:do_not_greet]               = false
      attrs.delete(:greeting_name)
    when 'custom'
      attrs[:use_full_name_for_greeting] = false
      attrs[:use_username_for_greeting]  = false
      attrs[:do_not_greet]               = false
    when 'do_not_greet'
      attrs[:use_full_name_for_greeting] = false
      attrs[:use_username_for_greeting]  = false
      attrs[:do_not_greet]               = true
      attrs[:greeting_name]              = ''
    end
  end

  def find_existing_user_by_email(email)
    normalized_email = email.to_s.strip.downcase
    return nil if normalized_email.blank?

    User.lookup_by_email(normalized_email)
  end
end
