# Adds the credential privileges, the starter role that bundles them, and the member email
# templates to databases that already exist. Fresh databases get them from db:seed.
class SeedCredentialPrivilegesAndEmailTemplates < ActiveRecord::Migration[8.1]
  TEMPLATE_KEYS = %w[credential_expiring_soon credential_expired credentials_revoked].freeze

  def up
    Privilege.seed_defaults!
    Role.seed_defaults!
    EmailTemplate.seed_defaults!
  end

  def down
    EmailTemplate.where(key: TEMPLATE_KEYS).destroy_all
    Role.where(name: 'Credentials administrator').destroy_all
    Privilege.where('key LIKE ?', 'credentials.%').destroy_all
  end
end
