class ApplicationGroupsController < AuthenticatedController
  include AuthentikGroupSyncing

  before_action -> { require_privilege!(:'settings.applications') }
  before_action :set_application
  before_action :set_application_group, only: %i[show edit update destroy add_user remove_user sync_to_authentik]

  def show
    @users = @application_group.effective_members.merge(User.ordered_by_display_name)
    @all_users = User.ordered_by_display_name
    @unsyncable_members = @application_group.unsyncable_members
  end

  def new
    @application_group = @application.application_groups.build(member_source: 'manual')
    load_form_data
    set_default_authentik_name
  end

  def edit
    load_form_data
  end

  def create
    @application_group = @application.application_groups.build(application_group_params)
    resolve_sync_group_combined(@application_group)

    if @application_group.save
      sync_result = sync_group_to_authentik(@application_group)
      notice = build_sync_notice('Application group created successfully.', sync_result)
      redirect_to application_application_group_path(@application, @application_group), notice: notice
    else
      load_form_data
      flash.now[:alert] = 'Unable to create application group.'
      render :new, status: :unprocessable_content
    end
  end

  def update
    @application_group.assign_attributes(application_group_params)
    resolve_sync_group_combined(@application_group)

    if @application_group.save
      sync_result = sync_group_to_authentik(@application_group)
      notice = build_sync_notice('Application group updated successfully.', sync_result)
      redirect_to application_application_group_path(@application, @application_group), notice: notice
    else
      load_form_data
      flash.now[:alert] = 'Unable to update application group.'
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    blocked = @application_group.deletion_blocked_message
    if blocked
      redirect_to application_application_group_path(@application, @application_group), alert: blocked
      return
    end

    delete_authentik_group(@application_group)
    group_name = @application_group.name
    @application_group.destroy!
    redirect_to application_path(@application), notice: "Application group '#{group_name}' deleted."
  end

  def add_user
    if @application_group.uses_default_group?
      redirect_to application_application_group_path(@application, @application_group),
                  alert: 'Cannot add members to a group that uses a default group.'
      return
    end

    user = User.find(params[:user_id])

    if @application_group.users.include?(user)
      redirect_to application_application_group_path(@application, @application_group),
                  alert: 'Member is already in this group.'
    else
      @application_group.users << user

      sync_result = sync_group_members(@application_group)
      notice = build_sync_notice('Member added to group.', sync_result)
      redirect_to application_application_group_path(@application, @application_group), notice: notice
    end
  end

  def remove_user
    if @application_group.uses_default_group?
      redirect_to application_application_group_path(@application, @application_group),
                  alert: 'Cannot remove members from a group that uses a default group.'
      return
    end

    user = User.find(params[:user_id])
    @application_group.users.delete(user)

    sync_result = sync_group_members(@application_group)
    notice = build_sync_notice('Member removed from group.', sync_result)
    redirect_to application_application_group_path(@application, @application_group), notice: notice
  end

  def sync_to_authentik
    unless MemberSource.enabled?('member_zone')
      redirect_to application_application_group_path(@application, @application_group),
                  alert: 'Member Zone source is disabled.'
      return
    end

    sync_result = sync_group_to_authentik(@application_group)

    if sync_result[:status] == 'error'
      redirect_to application_application_group_path(@application, @application_group),
                  alert: "Sync failed: #{sync_result[:error]}"
    else
      notice = build_sync_notice('Group synced to Authentik.', sync_result)
      redirect_to application_application_group_path(@application, @application_group), notice: notice
    end
  end

  private

  def set_application
    @application = Application.find(params[:application_id])
  end

  def set_application_group
    @application_group = @application.application_groups.find(params[:id])
  end

  def application_group_params
    params.expect(
      application_group: %i[name authentik_name authentik_group_id note
                            member_source sync_with_group_id training_topic_id]
    )
  end

  def load_form_data
    @training_topics = TrainingTopic.order(:name)
    @default_settings = DefaultSetting.instance
    @syncable_groups = build_syncable_groups_list
  end

  def build_syncable_groups_list
    all_groups = ApplicationGroup.includes(:application).ordered_by_name
    all_groups = all_groups.where.not(id: @application_group.id) if @application_group.persisted?
    all_groups.to_a
  end

  def resolve_sync_group_combined(group)
    return unless group.member_source == 'sync_group'

    combined = params.dig(:application_group, :sync_group_combined).to_s
    case combined
    when 'active_members', 'admin_members', 'unbanned_members', 'all_members'
      group.member_source = combined
      group.sync_with_group_id = nil
    when /\Async_group:(\d+)\z/
      group.sync_with_group_id = ::Regexp.last_match(1).to_i
    end
  end

  def set_default_authentik_name
    prefix = @application.authentik_prefix.presence || DefaultSetting.instance.app_prefix
    @application_group.authentik_name = "#{prefix}:"
  end
end
