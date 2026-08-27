class SeedOutgoingEmailBannerFragment < ActiveRecord::Migration[8.1]
  def up
    TextFragment.ensure_exists!(
      key: 'outgoing_email_banner',
      title: 'Outgoing email banner',
      content: ''
    )
  end

  def down
    TextFragment.where(key: 'outgoing_email_banner').delete_all
  end
end
