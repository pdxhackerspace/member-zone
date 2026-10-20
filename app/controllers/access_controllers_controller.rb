class AccessControllersController < AuthenticatedController
  before_action -> { require_privilege!(:'access.manage_controllers') }
  before_action :set_access_controller, only: %i[show edit update destroy toggle sync run_verb]

  def index
    @access_controllers = AccessController.includes(:access_controller_type).ordered
    @recent_logs = AccessControllerLog.includes(:access_controller).recent(50)
  end

  def show; end

  def new
    @access_controller = AccessController.new
    @access_controller_types = AccessControllerType.ordered
  end

  def edit
    @access_controller_types = AccessControllerType.ordered
  end

  def create
    @access_controller = AccessController.new(access_controller_params)

    if @access_controller.save
      redirect_to access_controllers_path, notice: "Access controller '#{@access_controller.name}' created."
    else
      @access_controller_types = AccessControllerType.ordered
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @access_controller.update(access_controller_params)
      redirect_to access_controllers_path, notice: "Access controller '#{@access_controller.name}' updated."
    else
      @access_controller_types = AccessControllerType.ordered
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    name = @access_controller.name
    @access_controller.destroy!
    redirect_to access_controllers_path, notice: "Access controller '#{name}' deleted."
  end

  def toggle
    @access_controller.update!(enabled: !@access_controller.enabled)
    status = @access_controller.enabled? ? 'enabled' : 'disabled'
    redirect_to access_controllers_path, notice: "Access controller '#{@access_controller.name}' #{status}."
  end

  def sync
    if @access_controller.enabled?
      AccessControllerVerbJob.perform_later(@access_controller.id, 'sync', current_user.id)
      redirect_to access_controllers_path, notice: "Sync started for '#{@access_controller.name}'."
    else
      redirect_to access_controllers_path, alert: "Access controller '#{@access_controller.name}' is disabled."
    end
  end

  def run_verb
    action = params[:action_name].to_s.strip
    actions = Array(@access_controller.access_controller_type&.actions)

    if action.blank? || actions.exclude?(action)
      redirect_to access_controllers_path, alert: 'Invalid access controller verb.'
      return
    end

    if @access_controller.enabled?
      AccessControllerVerbJob.perform_later(@access_controller.id, action, current_user.id)
      redirect_to access_controllers_path, notice: "Command '#{action}' started for '#{@access_controller.name}'."
    else
      redirect_to access_controllers_path, alert: "Access controller '#{@access_controller.name}' is disabled."
    end
  end

  def sync_all
    count = AccessControllers::MemberKeysSync.enqueue!(actor_user_id: current_user.id)
    notice = if count.positive?
               "Sync started for #{count} access controller#{'s' if count != 1}."
             else
               AccessControllers::MemberKeysSync.user_notice(0).strip
             end

    redirect_user_id = params[:redirect_user_id].presence
    if redirect_user_id.present? && User.exists?(redirect_user_id)
      suffix = count.positive? ? ' The new key fob will work after each controller finishes syncing.' : ''
      redirect_to user_path(redirect_user_id), notice: "#{notice}#{suffix}"
    else
      redirect_to access_controllers_path, notice: notice
    end
  end

  def toggle_sync_inactive
    settings = DefaultSetting.instance
    settings.update!(sync_inactive_members: !settings.sync_inactive_members)
    status = settings.sync_inactive_members? ? 'active and inactive' : 'active only'
    redirect_to access_controllers_path, notice: "Member sync updated: now syncing #{status} members."
  end

  # JSON endpoint for live polling of recent logs
  def recent_logs
    since = params[:since].present? ? Time.zone.parse(params[:since]) : 1.hour.ago
    logs = AccessControllerLog.includes(:access_controller)
                              .where('created_at >= ? OR status = ?', since, 'running')
                              .order(created_at: :desc)
                              .limit(50)

    render json: logs.map { |log|
      {
        id: log.id,
        controller_id: log.access_controller_id,
        controller_name: log.access_controller&.name || 'Deleted',
        action: log.action,
        status: log.status,
        exit_code: log.exit_code,
        command_line: log.command_line,
        output: log.output,
        created_at: log.created_at.strftime('%Y-%m-%d %H:%M:%S'),
        duration: log.duration
      }
    }
  end

  private

  def set_access_controller
    @access_controller = AccessController.includes(:access_controller_type).find(params[:id])
  end

  def access_controller_params
    params.expect(access_controller: %i[
                    name nickname hostname description access_token
                    script_arguments environment_variables enabled
                    display_order access_controller_type_id
                  ])
  end
end
