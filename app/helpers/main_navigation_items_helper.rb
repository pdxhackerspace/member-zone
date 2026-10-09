# The navbar's contents, kept apart from the logic that filters them so that adding a
# destination is an edit to a list rather than to a rule. MainNavigationHelper reads these;
# see it for what `privilege:`, `always:` and the :settings_hub sentinel mean.
module MainNavigationItemsHelper
  # Controllers whose pages count as "inside Settings" for the purpose of highlighting.
  SETTINGS_CONTROLLERS = %w[
    settings applications application_groups text_fragments documents incoming_webhooks
    rooms printers application_form_pages application_form_questions ai_ollama_profiles
    ai_providers interests member_sources rfid_readers access_controllers
    access_controller_types authentik_webhooks default_settings membership_settings
    payment_processors reminder_settings roles training_topics audit_log_sources
    audit_log_alert_rules credential_providers
  ].freeze

  private

  def members_nav_items
    [
      { key: 'members_index', label: 'Members', path: users_path, privilege: :'members.view_list' },
      { key: 'authentik', label: 'Authentik', path: authentik_users_path,
        privilege: :'sources.authentik.view' },
      { key: 'sheet', label: 'Sheet', path: sheet_entries_path, privilege: :'sources.sheet.view' },
      { key: 'slack', label: 'Slack', path: slack_users_path, privilege: :'sources.slack.view' },
      :divider,
      { key: 'applications', label: 'Applications', path: membership_applications_path,
        privilege: :'applications.view', controllers: %w[membership_applications] },
      { key: 'incident_reports', label: 'Incident Reports', path: incident_reports_path,
        privilege: :'incidents.manage', controllers: %w[incident_reports] },
      { key: 'onboarding', label: 'Onboarding', path: onboard_path,
        privilege: :'onboarding.run', controllers: %w[onboarding] }
    ]
  end

  def payments_nav_items
    [
      { key: 'paypal', label: 'PayPal', path: paypal_payments_path, privilege: :'payments.view' },
      { key: 'recharge', label: 'Recharge', path: recharge_payments_path, privilege: :'payments.view' },
      { key: 'kofi', label: 'Ko-Fi', path: kofi_payments_path, privilege: :'payments.view' },
      { key: 'cash', label: 'Cash', path: cash_payments_path,
        privilege: %i[payments.view payments.manage_cash] },
      :divider,
      { key: 'payment_events', label: 'Payment Events', path: payment_events_path,
        privilege: :'payments.view_events' }
    ]
  end

  def building_nav_items
    [
      { key: 'access_logs', label: 'Access', path: access_logs_path, privilege: :'access.view_logs' },
      { key: 'parking', label: 'Parking', path: parking_notices_path,
        privilege: :'parking.manage_notices', controllers: %w[parking_notices] }
    ]
  end

  def admin_nav_items
    [
      { key: 'reports', label: 'Reports', path: reports_path,
        privilege: :'reports.view', controllers: %w[reports] },
      { key: 'member_map', label: 'Map', path: member_map_path,
        privilege: :'member_map.view', controllers: %w[member_maps] },
      { key: 'credentials', label: 'Credentials', path: issued_credentials_path,
        privilege: :'credentials.view_all', controllers: %w[issued_credentials] },
      { key: 'queued_mail', label: 'Mail queue', path: queued_mails_path,
        privilege: :'queued_mail.view', controllers: %w[queued_mails] },
      { key: 'mail_log', label: 'Mail log', path: mail_log_path,
        privilege: :'mail_log.view', controllers: %w[mail_log] },
      { key: 'settings', label: 'Settings', path: settings_path,
        privilege: :settings_hub, controllers: SETTINGS_CONTROLLERS },
      { key: 'sidekiq', label: 'Sidekiq', path: '/goh7zeeNiezoozaingothu4', target: '_blank' }
    ]
  end
end
