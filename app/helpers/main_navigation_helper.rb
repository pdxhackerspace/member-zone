# The navbar, as data.
#
# The navbar is the only way a non-administrator with privileges reaches anything: `root`
# points at the dashboard, which needs dashboard.admin, so a holder without that key lands
# on their own profile. Without an entry here, an enforced privilege is unreachable unless
# the holder knows the URL.
#
# Nothing here enforces anything — each destination gates itself. An entry with no
# `privilege:` is administrator-only; Sidekiq is the only one left, because its console is
# outside the application and has no key to name.
module MainNavigationHelper
  def main_nav_entries
    [
      { key: 'members', label: 'Members', items: members_nav_items },
      { key: 'payments', label: 'Payments', items: payments_nav_items },
      { key: 'training', label: 'Training', path: training_catalog_path,
        controllers: %w[training_catalog], always: true },
      { key: 'journal', label: 'Journal', path: journals_path, privilege: :'journal.view' },
      { key: 'audit', label: 'Audit', path: audit_log_entries_path,
        privilege: %i[audit_logs.view_all audit_logs.view], any_topic: true, controllers: %w[audit_log_entries] },
      { key: 'building', label: 'Building', items: building_nav_items },
      { key: 'admin', label: 'Admin', items: admin_nav_items }
    ]
  end

  # Sections keep only the entries this account can see; a section with nothing left does
  # not render, and one left holding a single entry renders as a flat link rather than a
  # dropdown containing one thing.
  def visible_nav_entries
    main_nav_entries.filter_map do |entry|
      next (entry if nav_entry_visible?(entry)) unless entry[:items]

      items = compact_nav_dividers(entry[:items].select { |item| item == :divider || nav_entry_visible?(item) })
      next if items.none? { |item| item != :divider }

      real = items.reject { |item| item == :divider }
      real.one? ? real.first : entry.merge(items: items)
    end
  end

  def nav_entry_visible?(entry)
    return true if entry[:always]
    # The hub is a directory, so it appears for anyone with a row to open rather than
    # needing a grant of its own — see SettingsHelper#visible_settings_items.
    return settings_nav_visible? if entry[:privilege] == :settings_hub
    return current_user_admin? if entry[:privilege].blank?

    # An entry may name several keys when its destination admits several — the cash ledger
    # is readable with payments.view and writable with payments.manage_cash — in which case
    # any one of them shows the link, mirroring require_any_privilege!.
    Array(entry[:privilege]).any? do |privilege|
      entry[:any_topic] ? can_for_any_topic?(privilege) : can?(privilege)
    end
  end

  # Whether to render the privileged half of the navbar at all.
  def privileged_nav_visible?
    current_user_admin? || visible_nav_entries.any?
  end

  # A parent is active when any of its children is, so nothing has to be maintained by hand.
  def nav_entry_active?(entry)
    return true if entry[:controllers]&.include?(controller_name)
    return true if entry[:path].present? && !entry[:items] && current_page?(entry[:path])

    Array(entry[:items]).any? { |item| item != :divider && nav_entry_active?(item) }
  end

  # Dividers only mean something between two entries: drop them when they end up leading,
  # trailing, or doubled after filtering, or a menu renders a stray rule.
  def compact_nav_dividers(items)
    items
      .chunk_while { |a, b| a == :divider && b == :divider }.map(&:first)
      .drop_while { |item| item == :divider }
      .reverse.drop_while { |item| item == :divider }.reverse
  end

  private

  def settings_nav_visible?
    can?(:'settings.view') || visible_settings_items.any?
  end
end
