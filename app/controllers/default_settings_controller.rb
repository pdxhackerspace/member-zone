class DefaultSettingsController < AuthenticatedController
  before_action -> { require_privilege!(:'settings.defaults') }
  def show
    @default_setting = DefaultSetting.instance
    @custom_core_groups = ApplicationGroup.custom_core.includes(:users, :sync_dependents).ordered_by_name
    @builtin_core_groups = ApplicationGroup.builtin_core.includes(:application, :sync_dependents).ordered_by_name
    @never_synced_count = @custom_core_groups.count { |group| group.authentik_group_id.blank? }
  end

  def edit
    @default_setting = DefaultSetting.instance
  end

  def map
    @default_setting = DefaultSetting.instance
  end

  def edit_map
    @default_setting = DefaultSetting.instance
  end

  def branding
    @default_setting = DefaultSetting.instance
    @login_message_fragment = login_message_fragment
  end

  def edit_branding
    @default_setting = DefaultSetting.instance
    @login_message_fragment = login_message_fragment
  end

  def provision_core_groups
    provisioner = Authentik::CoreGroupProvisioner.new
    results = provisioner.provision_and_sync!

    parts = []
    parts << "Created: #{results[:created].join(', ')}" if results[:created].any?
    parts << "Already existed: #{results[:existing].count}" if results[:existing].any?
    parts << "Synced: #{results[:synced].count}" if results[:synced].any?
    parts << "Errors: #{results[:errors].join('; ')}" if results[:errors].any?

    notice = "Core groups provisioned. #{parts.join('. ')}."
    redirect_to default_settings_path, notice: notice
  end

  def update
    @default_setting = DefaultSetting.instance

    if @default_setting.update(default_setting_params)
      redirect_to default_settings_path, notice: 'Default settings updated successfully.'
    else
      flash.now[:alert] = 'Unable to update default settings.'
      render :edit, status: :unprocessable_content
    end
  end

  def update_map
    @default_setting = DefaultSetting.instance

    if @default_setting.update(map_default_setting_params)
      redirect_to map_default_settings_path, notice: 'Map defaults updated successfully.'
    else
      flash.now[:alert] = 'Unable to update map defaults.'
      render :edit_map, status: :unprocessable_content
    end
  end

  def update_branding
    @default_setting = DefaultSetting.instance
    @login_message_fragment = login_message_fragment
    update_succeeded = false

    DefaultSetting.transaction do
      updated_default_setting = @default_setting.update(branding_default_setting_params)
      updated_fragment = @login_message_fragment.update(content: branding_text_fragment_params[:content])
      update_succeeded = updated_default_setting && updated_fragment
      raise ActiveRecord::Rollback unless update_succeeded
    end

    if update_succeeded
      apply_branding_image_removals(@default_setting)
      redirect_to branding_default_settings_path, notice: 'Login branding updated successfully.'
    else
      flash.now[:alert] = 'Unable to update login branding.'
      render :edit_branding, status: :unprocessable_content
    end
  end

  private

  def default_setting_params
    params.expect(default_setting: %i[
                    site_prefix app_prefix members_prefix
                    active_members_group admins_group
                    unbanned_members_group all_members_group
                    trained_on_prefix can_train_prefix
                    sync_inactive_members
                  ])
  end

  def map_default_setting_params
    params.expect(default_setting: %i[
                    map_center_latitude map_center_longitude
                    map_radius_miles map_default_city map_default_state
                  ])
  end

  def branding_default_setting_params
    params.fetch(:default_setting, ActionController::Parameters.new).permit(
      :login_branding_image, :login_background_image, :login_keyfob_sign_in_enabled
    )
  end

  def branding_text_fragment_params
    params.expect(login_message_fragment: [:content])
  end

  def apply_branding_image_removals(default_setting)
    raw_params = params.fetch(:default_setting, {})
    if branding_image_marked_for_removal?(raw_params, :remove_login_branding_image, :login_branding_image)
      default_setting.login_branding_image.purge
    end
    if branding_image_marked_for_removal?(raw_params, :remove_login_background_image, :login_background_image)
      default_setting.login_background_image.purge
    end
  end

  def branding_image_marked_for_removal?(raw_params, remove_key, upload_key)
    ActiveModel::Type::Boolean.new.cast(raw_params[remove_key]) && raw_params[upload_key].blank?
  end

  def login_message_fragment
    TextFragment.ensure_exists!(
      key: 'login_screen_message',
      title: 'Login Screen Message',
      content: ''
    )
  end
end
