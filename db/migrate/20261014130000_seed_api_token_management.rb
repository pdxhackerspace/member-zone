# Adds the api.tokens.manage privilege, the API token expiry reminder, and its email template to
# databases that already exist. Fresh databases get them from db:seed.
class SeedApiTokenManagement < ActiveRecord::Migration[8.1]
  def up
    Privilege.seed_defaults!
    ReminderSetting.seed_defaults!
    EmailTemplate.seed_defaults!
  end

  def down
    EmailTemplate.where(key: 'api_token_expiring_soon').destroy_all
    ReminderSetting.where(key: 'api_token_expiry').destroy_all
    Privilege.where(key: 'api.tokens.manage').destroy_all
  end
end
