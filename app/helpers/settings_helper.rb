# The settings hub's contents, in one place so the page, its counts, its search modal and
# the navbar entry all agree on what a given account can see.
#
# `privilege:` is the key that reveals a row. A row with no key stays with administrators —
# that is the default rather than an oversight, and each later phase moves rows off it as
# the matching privilege gets enforced.
# rubocop:disable Metrics/ModuleLength -- a catalogue; its length is its contents
module SettingsHelper
  def settings_items
    membership_settings_items + access_settings_items + payment_settings_items +
      communication_settings_items + profile_settings_items + integration_settings_items +
      system_settings_items
  end

  # What this account may actually open. Everything downstream — the header count, the
  # category sidebar, the attention list and the Cmd+K results — derives from this, so
  # filtering once here fixes all of them.
  def visible_settings_items
    settings_items.select { |item| settings_item_visible?(item) }
  end

  def settings_item_visible?(item)
    return current_user_admin? if item[:privilege].blank?

    can?(item[:privilege])
  end

  private

  # Only SettingsController#index computes these; the navbar asks for the same list on
  # every other page, where there are none.
  def settings_attention_counts
    @settings_attention_counts || {}
  end

  def membership_settings_items
    [
      { category: 'Membership', title: 'Application form', privilege: :'applications.configure_form',
        desc: 'Pages and questions for the public membership application.', path: application_form_pages_path },
      { category: 'Membership', title: 'Applications', privilege: :'settings.applications',
        desc: 'Applications, groups, and member application assignments.', path: applications_path },
      { category: 'Membership', title: 'Application group defaults', privilege: :'settings.defaults',
        desc: 'Default prefixes and group names for application groups.', path: default_settings_path },
      { category: 'Membership', title: 'Invitations', privilege: :'invitations.view',
        desc: 'Membership invitations, status, and linked member accounts.', path: invitations_path },
      { category: 'Membership', title: 'Membership tiers', privilege: :'plans.manage',
        desc: 'Plans, billing frequencies, costs, and member dues settings.', path: membership_plans_path },
      { category: 'Membership', title: 'Membership settings', privilege: :'membership_settings.manage',
        desc: 'Grace periods, reactivation windows, and manual payment timing.', path: membership_settings_path }
    ]
  end

  def access_settings_items
    [
      { category: 'Access & hardware', title: 'Access controllers', privilege: :'access.manage_controllers',
        desc: 'RFID-enabled door controllers and device sync status.', path: access_controllers_path,
        attention_count: settings_attention_counts[:access_controllers] },
      { category: 'Access & hardware', title: 'Access controller types', privilege: :'access.manage_controller_types',
        desc: 'SSH script types and optional access tokens.', path: access_controller_types_path },
      { category: 'Access & hardware', title: 'Authentik webhooks', privilege: :'settings.authentik_webhooks',
        desc: 'User and group change notifications from Authentik.', path: authentik_webhooks_path },
      { category: 'Access & hardware', title: 'Incoming webhooks', privilege: :'webhooks.incoming.manage',
        desc: 'Webhook URLs for RFID, Ko-Fi, access logs, and integrations.', path: incoming_webhooks_path },
      { category: 'Access & hardware', title: 'RFID readers', privilege: :'access.manage_readers',
        desc: 'Reader devices and API keys for keyfob authentication.', path: rfid_readers_path },
      { category: 'Access & hardware', title: 'Rooms', privilege: :'parking.manage_rooms',
        desc: 'Rooms and locations used by parking and operations.', path: rooms_path },
      { category: 'Access & hardware', title: 'Printers', privilege: :'parking.manage_printers',
        desc: 'CUPS printers for notices, reports, and documents.', path: printers_path }
    ]
  end

  def payment_settings_items
    [
      { category: 'Payments', title: 'Payment processors', privilege: :'payments.manage_processors',
        desc: 'PayPal, Recharge, and Ko-Fi integration sync health.', path: payment_processors_path,
        attention_count: settings_attention_counts[:payment_processors] },
      { category: 'Payments', title: 'Recharge', privilege: :'payments.view',
        desc: 'Recharge records that may need member linking.', path: recharge_payments_path,
        attention_count: settings_attention_counts[:recharge] },
      { category: 'Payments', title: 'Dues', privilege: :'membership_settings.manage',
        desc: 'Dues windows and manual payment settings.', path: membership_settings_path }
    ]
  end

  def communication_settings_items
    [
      { category: 'Communications', title: 'Email templates', privilege: :'email_templates.view',
        desc: 'Messages sent for applications, approvals, payments, and more.', path: email_templates_path,
        attention_count: settings_attention_counts[:email_templates] },
      { category: 'Communications', title: 'Reminders',
        desc: 'Automated member reminders with preview of who would be emailed.', path: reminder_settings_path,
        attention_count: settings_attention_counts[:reminders_due] },
      { category: 'Communications', title: 'Email opt-outs',
        desc: 'Email addresses that opted out of applicant reminders.', path: email_notification_opt_outs_path },
      { category: 'Communications', title: 'Documents', privilege: :'training.documents.view_all',
        desc: 'Member documents and training-topic attachments.', path: documents_path },
      { category: 'Communications', title: 'Login branding', privilege: :'settings.defaults',
        desc: 'Login screen text, branding image, and background uploads.', path: branding_default_settings_path },
      { category: 'Communications', title: 'Text fragments', privilege: :'text_fragments.manage',
        desc: 'Reusable HTML snippets for help text, system messages, and the optional email banner.', path: text_fragments_path }
    ]
  end

  def profile_settings_items
    [
      { category: 'Member profiles', title: 'Interests', privilege: :'settings.interests',
        desc: 'Profile interests, suggested terms, renames, and merges.', path: interests_path,
        attention_count: settings_attention_counts[:interests] },
      { category: 'Member profiles', title: 'Map defaults', privilege: :'settings.defaults',
        desc: 'Hackerspace location and fallback city/state for member geocoding.', path: map_default_settings_path }
    ]
  end

  def integration_settings_items
    [
      { category: 'AI & integrations', title: 'AI services', privilege: :'settings.ai_services',
        desc: 'Service prompts, model selections, and health checks.', path: ai_ollama_profiles_path,
        attention_count: settings_attention_counts[:ai_services] },
      { category: 'AI & integrations', title: 'AI providers', privilege: :'settings.ai_providers',
        desc: 'Reusable AI provider URLs and optional API keys.', path: ai_providers_path },
      { category: 'AI & integrations', title: 'Member sources', privilege: :'sources.manage',
        desc: 'Authentik, Sheets, and Slack reconciliation sources.', path: member_sources_path }
    ]
  end

  def system_settings_items
    [
      { category: 'System', title: 'Training topics', privilege: :'training.topics.manage',
        desc: 'Topics members can learn or train others on.', path: training_topics_path },
      # Roles hand out privileges, so managing them stays with administrators until the
      # no-escalation containment in User#may_confer? is proven under privilege gates.
      { category: 'System', title: 'Roles',
        desc: 'Privilege bundles conferred by the training topics that carry them.', path: roles_path }
    ]
  end
end
# rubocop:enable Metrics/ModuleLength
