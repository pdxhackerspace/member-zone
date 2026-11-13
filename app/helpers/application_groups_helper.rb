module ApplicationGroupsHelper
  SYNCABLE_GROUP_SECTIONS = [
    [:builtin, 'Built-in core groups'],
    [:custom, 'Custom core groups'],
    [:other, 'Other groups']
  ].freeze

  def system_application_id
    return @system_application_id if defined?(@system_application_id)

    @system_application_id = Authentik::CoreGroupProvisioner.existing_system_application&.id
  end

  def core_group?(group)
    system_application_id.present? && group.application_id == system_application_id
  end

  def custom_core_group?(group)
    core_group?(group) && group.manual?
  end

  # Hand-managed core groups have their own pages. Everything else stays on the application.
  def group_management_path(group)
    return default_settings_core_group_path(group) if custom_core_group?(group)

    application_application_group_path(group.application, group)
  end

  def add_group_member_path(group, user)
    if custom_core_group?(group)
      add_user_default_settings_core_group_path(group, user_id: user.id)
    else
      add_user_application_application_group_path(group.application, group, user_id: user.id)
    end
  end

  def remove_group_member_path(group, user)
    if custom_core_group?(group)
      remove_user_default_settings_core_group_path(group, user_id: user.id)
    else
      remove_user_application_application_group_path(group.application, group, user_id: user.id)
    end
  end

  def syncable_group_sections(groups)
    grouped = groups.group_by { |group| syncable_group_section_key(group) }
    SYNCABLE_GROUP_SECTIONS.filter_map do |key, label|
      section = grouped[key]
      [label, section] if section.present?
    end
  end

  def syncable_group_option_label(group)
    return group.name if core_group?(group)

    "#{group.name} (#{group.application.name})"
  end

  def group_needs_sync_attention?(group)
    return true if group.authentik_group_id.blank?
    return false unless group.manual?

    group.users.any? { |user| user.authentik_id.blank? }
  end

  def group_sync_status(group)
    return never_synced_status if group.authentik_group_id.blank?

    unsyncable = unsyncable_member_count(group)
    return unsyncable_status(unsyncable) if unsyncable.positive?

    tag.span(nil, class: 'status-dot status-success', title: 'Synced')
  end

  def counted_value(count)
    tag.span(count, class: count.zero? ? 'text-secondary' : 'text-body')
  end

  private

  def syncable_group_section_key(group)
    return :other unless core_group?(group)

    group.manual? ? :custom : :builtin
  end

  def unsyncable_member_count(group)
    return 0 unless group.manual?

    group.users.count { |user| user.authentik_id.blank? }
  end

  def never_synced_status
    safe_join([
                tag.span(nil, class: 'status-dot status-warning me-1', title: 'Never synced'),
                tag.span('Never synced', class: 'badge text-bg-warning-subtle')
              ])
  end

  def unsyncable_status(count)
    label = "#{count} can't sync"
    safe_join([
                tag.span(nil, class: 'status-dot status-warning me-1', title: label),
                tag.span(label, class: 'badge text-bg-warning-subtle')
              ])
  end
end
