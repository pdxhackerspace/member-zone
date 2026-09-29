# Adds the audit log privileges, the two starter roles that bundle them, and the alert email
# template to databases that already exist. Fresh databases get them from db:seed.
class SeedAuditLogPrivilegesAndEmailTemplate < ActiveRecord::Migration[8.1]
  def up
    Privilege.seed_defaults!
    Role.seed_defaults!
    EmailTemplate.seed_defaults!
  end

  def down
    EmailTemplate.where(key: 'audit_log_alert').destroy_all
    Role.where(name: ['Audit log administrator', 'Audit log reviewer']).destroy_all
    Privilege.where('key LIKE ?', 'audit_logs.%').destroy_all
  end
end
