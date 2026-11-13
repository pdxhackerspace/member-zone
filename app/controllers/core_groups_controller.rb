class CoreGroupsController < AuthenticatedController
  include AuthentikGroupSyncing

  before_action -> { require_privilege!(:'settings.defaults') }
  before_action :set_core_group, only: %i[show edit update destroy add_user remove_user sync_to_authentik]

  def show
    @users = @core_group.effective_members.merge(User.ordered_by_display_name)
    @all_users = User.ordered_by_display_name
    @unsyncable_members = @core_group.unsyncable_members
    @dependents = @core_group.sync_dependents.includes(:application).ordered_by_name
  end

  def new
    @core_group = system_groups.build(member_source: 'manual')
    @core_group.authentik_name = "#{DefaultSetting.instance.members_prefix}:"
  end

  def edit; end

  def create
    @core_group = system_groups.build(core_group_params.merge(member_source: 'manual'))
    save_core_group('Core group created.', 'create', :new)
  end

  def update
    @core_group.assign_attributes(core_group_params)
    save_core_group('Core group updated.', 'update', :edit)
  end

  def destroy
    blocked = @core_group.deletion_blocked_message
    if blocked
      redirect_to default_settings_core_group_path(@core_group), alert: blocked
      return
    end

    delete_authentik_group(@core_group)
    name = @core_group.name
    @core_group.destroy!
    redirect_to default_settings_path, notice: "Core group '#{name}' deleted."
  end

  def add_user
    user = User.find(params[:user_id])
    if @core_group.users.include?(user)
      redirect_to default_settings_core_group_path(@core_group), alert: 'Member is already in this group.'
      return
    end

    @core_group.users << user
    notice = build_sync_notice('Member added to group.', sync_group_members(@core_group))
    redirect_to default_settings_core_group_path(@core_group), notice: notice
  end

  def remove_user
    user = User.find(params[:user_id])
    @core_group.users.delete(user)
    notice = build_sync_notice('Member removed from group.', sync_group_members(@core_group))
    redirect_to default_settings_core_group_path(@core_group), notice: notice
  end

  def sync_to_authentik
    unless MemberSource.enabled?('member_zone')
      redirect_to default_settings_core_group_path(@core_group), alert: 'Member Zone source is disabled.'
      return
    end

    finish_sync(sync_group_to_authentik(@core_group))
  end

  private

  def set_core_group
    @core_group = custom_core_groups.find(params[:id])
  end

  def system_groups
    Authentik::CoreGroupProvisioner.system_application.application_groups
  end

  def custom_core_groups
    application = Authentik::CoreGroupProvisioner.existing_system_application
    return ApplicationGroup.none if application.nil?

    application.application_groups.with_member_sources('manual')
  end

  def core_group_params
    params.expect(core_group: %i[name authentik_name note])
  end

  def save_core_group(success_message, verb, failure_template)
    if @core_group.save
      notice = build_sync_notice(success_message, sync_group_to_authentik(@core_group))
      redirect_to default_settings_core_group_path(@core_group), notice: notice
    else
      flash.now[:alert] = "Unable to #{verb} core group."
      render failure_template, status: :unprocessable_content
    end
  end

  def finish_sync(sync_result)
    if sync_result[:status] == 'error'
      redirect_to default_settings_core_group_path(@core_group), alert: "Sync failed: #{sync_result[:error]}"
    else
      notice = build_sync_notice('Group synced to Authentik.', sync_result)
      redirect_to default_settings_core_group_path(@core_group), notice: notice
    end
  end
end
