class SeedAnnouncerFragmentAndPrivilege < ActiveRecord::Migration[8.1]
  def up
    Privilege.seed_defaults!
    TextFragment.ensure_exists!(
      key: 'announce_arrivals_help',
      title: 'Announce arrivals (profile help text)',
      content: <<~HTML
        <p>When you badge in at an outside door, we can let people know you've arrived.
        Choose where below. We never announce when you leave.</p>
      HTML
    )
  end

  def down
    TextFragment.where(key: 'announce_arrivals_help').delete_all
    Privilege.where(key: 'announcers.manage').destroy_all
  end
end
