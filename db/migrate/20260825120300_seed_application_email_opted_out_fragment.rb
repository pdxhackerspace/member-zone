class SeedApplicationEmailOptedOutFragment < ActiveRecord::Migration[8.1]
  def up
    TextFragment.ensure_exists!(
      key: 'application_email_opted_out',
      title: 'Application email opted out',
      content: <<~HTML
        <p>This email address has opted out of messages from us.</p>
        <p>To opt back in and apply for membership, please email <a href="mailto:info@pdxhackerspace.org">info@pdxhackerspace.org</a> from this same address.</p>
      HTML
    )
  end

  def down
    TextFragment.where(key: 'application_email_opted_out').delete_all
  end
end
