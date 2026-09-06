# A single grantable capability. Privileges are never attached to a training topic
# directly; they are bundled into roles, and roles are attached to topics.
#
# Scope determines how a conferred privilege applies:
#   global - applies everywhere once conferred by any topic the member holds
#   topic  - applies only for the topic that conferred it
class Privilege < ApplicationRecord
  SCOPES = %w[global topic].freeze

  has_many :role_privileges, dependent: :destroy
  has_many :roles, through: :role_privileges

  validates :key, presence: true, uniqueness: true
  validates :label, presence: true
  validates :privilege_scope, presence: true, inclusion: { in: SCOPES }

  scope :global, -> { where(privilege_scope: 'global') }
  scope :topic_scoped, -> { where(privilege_scope: 'topic') }
  scope :ordered, -> { order(:category, :key) }

  # rubocop:disable-next Layout/LineLength
  CATALOG = [
    { key: 'members.view_list', label: 'View member directory', category: 'Members & profiles' },
    { key: 'members.view_profile', label: 'View full member profiles', category: 'Members & profiles' },
    { key: 'members.view_private_contact', label: 'View private contact info', category: 'Members & profiles' },
    { key: 'members.create', label: 'Create members', category: 'Members & profiles' },
    { key: 'members.edit_profile', label: 'Edit member profiles', category: 'Members & profiles' },
    { key: 'members.edit_membership', label: 'Edit membership status and plan', category: 'Members & profiles' },
    { key: 'members.edit_notes', label: 'Edit internal notes', category: 'Members & profiles' },
    { key: 'members.toggle_active', label: 'Activate and deactivate service accounts', category: 'Members & profiles' },
    { key: 'members.emergency_active_override', label: 'Set emergency active override', category: 'Members & profiles' },
    { key: 'members.ban', label: 'Ban members', category: 'Members & profiles' },
    { key: 'members.mark_deceased', label: 'Mark members deceased', category: 'Members & profiles' },
    { key: 'members.sponsor', label: 'Sponsor and unsponsor members', category: 'Members & profiles' },
    { key: 'members.delete', label: 'Delete members', category: 'Members & profiles' },
    # No members.impersonate. Impersonation makes authorization resolve against the account
    # being viewed as, which is only ever a reduction because only an administrator can start
    # it and administrators hold everything. A non-administrator able to impersonate an
    # administrator would gain authority instead, so this must not be conferrable by role.
    { key: 'members.grant_admin', label: 'Grant and revoke admin', category: 'Members & profiles' },
    { key: 'members.send_message', label: 'Send new messages to members', category: 'Members & profiles' },
    { key: 'members.sync_authentik', label: 'Push and pull a member to Authentik', category: 'External sources' },
    { key: 'members.unlink_sources', label: 'Unlink Slack, Authentik, and Sheet records', category: 'External sources' },
    { key: 'access.view_rfids', label: 'View member key fobs', category: 'Key fobs & building access' },
    { key: 'access.manage_rfids', label: 'Add and remove member key fobs', category: 'Key fobs & building access' },
    { key: 'access.pause_resume', label: 'Pause and resume key access', category: 'Key fobs & building access' },
    { key: 'access.view_logs', label: 'View access logs', category: 'Key fobs & building access' },
    { key: 'access.import_logs', label: 'Import access logs', category: 'Key fobs & building access' },
    { key: 'access.link_logs', label: 'Link access log entries to members', category: 'Key fobs & building access' },
    { key: 'access.manage_controllers', label: 'Manage access controllers', category: 'Key fobs & building access' },
    { key: 'access.manage_controller_types', label: 'Manage access controller types', category: 'Key fobs & building access' },
    { key: 'access.manage_readers', label: 'Manage RFID readers', category: 'Key fobs & building access' },
    { key: 'access.export_users', label: 'Export users to controllers', category: 'Key fobs & building access' },
    { key: 'applications.view', label: 'View application queue', category: 'Membership applications' },
    { key: 'applications.view_pii', label: 'View applicant contact details', category: 'Membership applications' },
    { key: 'applications.review', label: 'Review applications, vote, and record tours', category: 'Membership applications' },
    { key: 'applications.link_member', label: 'Link applications to members', category: 'Membership applications' },
    { key: 'applications.import', label: 'Import applications from CSV', category: 'Membership applications' },
    { key: 'applications.manage_initiated', label: 'Manage initiated applications', category: 'Membership applications' },
    { key: 'applications.approve', label: 'Approve applications', category: 'Membership applications' },
    { key: 'applications.reject', label: 'Reject applications', category: 'Membership applications' },
    { key: 'applications.park_review', label: 'Park applications for review', category: 'Membership applications' },
    { key: 'applications.configure_form', label: 'Configure the application form', category: 'Membership applications' },
    { key: 'applications.create', label: 'Create applications manually', category: 'Membership applications' },
    { key: 'plans.view_hidden', label: 'View hidden membership plans', category: 'Plans & payments' },
    { key: 'plans.manage', label: 'Create, edit, and delete plans', category: 'Plans & payments' },
    { key: 'plans.manual_payments', label: 'Record manual dues', category: 'Plans & payments' },
    { key: 'membership_settings.manage', label: 'Edit grace periods and dues windows', category: 'Plans & payments' },
    { key: 'payments.view', label: 'View payment records', category: 'Plans & payments' },
    { key: 'payments.link', label: 'Link payments to members', category: 'Plans & payments' },
    { key: 'payments.import_export', label: 'Import and export payment data', category: 'Plans & payments' },
    { key: 'payments.sync', label: 'Trigger payment processor sync', category: 'Plans & payments' },
    { key: 'payments.manage_cash', label: 'Manage cash payments', category: 'Plans & payments' },
    { key: 'payments.manage_processors', label: 'Configure payment processors', category: 'Plans & payments' },
    { key: 'payments.view_events', label: 'View payment event log', category: 'Plans & payments' },
    { key: 'training.topics.manage', label: 'Manage training topics', category: 'Training & topic resources' },
    { key: 'training.topics.manage_links', label: 'Edit topic resource links', category: 'Training & topic resources', privilege_scope: 'topic' },
    { key: 'training.topics.edit_details', label: 'Edit topic descriptions', category: 'Training & topic resources', privilege_scope: 'topic' },
    { key: 'training.subtopics.create', label: 'Create subtopics', category: 'Training & topic resources', privilege_scope: 'topic' },
    { key: 'training.subtopics.manage', label: 'Rename and delete subtopics', category: 'Training & topic resources', privilege_scope: 'topic' },
    { key: 'training.record', label: 'Record training for others', category: 'Training & topic resources', privilege_scope: 'topic' },
    { key: 'training.revoke', label: 'Revoke training records', category: 'Training & topic resources', privilege_scope: 'topic' },
    { key: 'training.grant_trainer', label: 'Grant and revoke trainer capability', category: 'Training & topic resources' },
    { key: 'training.respond_requests', label: 'Respond to training requests', category: 'Training & topic resources', privilege_scope: 'topic' },
    { key: 'training.documents.manage', label: 'Manage topic documents', category: 'Training & topic resources', privilege_scope: 'topic' },
    { key: 'training.documents.view_all', label: 'View all documents', category: 'Training & topic resources' },
    { key: 'training.catalog.view_all', label: 'View every training topic', category: 'Training & topic resources' },
    { key: 'onboarding.run', label: 'Run the onboarding wizard', category: 'Onboarding & invitations' },
    { key: 'onboarding.approve_mail', label: 'Approve queued mail during onboarding', category: 'Onboarding & invitations' },
    { key: 'invitations.view', label: 'View invitations', category: 'Onboarding & invitations' },
    { key: 'invitations.create', label: 'Send invitations', category: 'Onboarding & invitations' },
    { key: 'invitations.cancel', label: 'Cancel invitations', category: 'Onboarding & invitations' },
    { key: 'sources.authentik.view', label: 'View Authentik users', category: 'External sources' },
    { key: 'sources.authentik.sync', label: 'Sync and link Authentik users', category: 'External sources' },
    { key: 'sources.slack.view', label: 'View Slack users', category: 'External sources' },
    { key: 'sources.slack.sync', label: 'Sync and import Slack users', category: 'External sources' },
    { key: 'sources.sheet.view', label: 'View sheet entries', category: 'External sources' },
    { key: 'sources.sheet.sync', label: 'Sync sheet entries', category: 'External sources' },
    { key: 'sources.manage', label: 'Configure member sources', category: 'External sources' },
    { key: 'email_templates.view', label: 'View email templates', category: 'Communications & content' },
    { key: 'email_templates.edit', label: 'Edit email templates', category: 'Communications & content' },
    { key: 'email_templates.test_send', label: 'Send test emails', category: 'Communications & content' },
    { key: 'email_templates.ai_rewrite', label: 'Rewrite templates with AI', category: 'Communications & content' },
    { key: 'queued_mail.view', label: 'View queued mail', category: 'Communications & content' },
    { key: 'queued_mail.approve', label: 'Approve and reject queued mail', category: 'Communications & content' },
    { key: 'queued_mail.edit', label: 'Edit queued mail', category: 'Communications & content' },
    { key: 'mail_log.view', label: 'View sent mail log', category: 'Communications & content' },
    { key: 'text_fragments.manage', label: 'Manage text fragments', category: 'Communications & content' },
    { key: 'webhooks.incoming.manage', label: 'Manage incoming webhooks', category: 'Communications & content' },
    { key: 'parking.manage_notices', label: 'Issue and clear parking notices', category: 'Parking & operations' },
    { key: 'parking.clear_admin_required', label: 'Clear notices needing staff clearance', category: 'Parking & operations' },
    { key: 'parking.manage_rooms', label: 'Manage rooms and locations', category: 'Parking & operations' },
    { key: 'parking.manage_printers', label: 'Manage printers', category: 'Parking & operations' },
    { key: 'incidents.manage', label: 'Manage incident reports', category: 'Parking & operations' },
    { key: 'settings.view', label: 'Access the settings hub', category: 'Settings & integrations' },
    { key: 'settings.defaults', label: 'Edit application group and map defaults', category: 'Settings & integrations' },
    { key: 'settings.applications', label: 'Manage Authentik applications and groups', category: 'Settings & integrations' },
    { key: 'settings.authentik_webhooks', label: 'Configure Authentik webhooks', category: 'Settings & integrations' },
    { key: 'settings.interests', label: 'Manage profile interests', category: 'Settings & integrations' },
    { key: 'settings.ai_providers', label: 'Manage AI providers', category: 'Settings & integrations' },
    { key: 'settings.ai_services', label: 'Manage AI service profiles', category: 'Settings & integrations' },
    { key: 'dashboard.admin', label: 'View the admin dashboard', category: 'Reports & audit' },
    { key: 'reports.view', label: 'View reports', category: 'Reports & audit' },
    { key: 'reports.edit_users', label: 'Edit members from reports', category: 'Reports & audit' },
    { key: 'journal.view', label: 'View the audit journal', category: 'Reports & audit' },
    { key: 'member_map.view', label: 'View the member map', category: 'Reports & audit' },
    { key: 'search.admin', label: 'Search all record types', category: 'Reports & audit' },
    { key: 'api.users.search', label: 'Use the member picker API', category: 'Reports & audit' },
    { key: 'help.admin_faq', label: 'View the admin FAQ', category: 'Reports & audit' }
  ].freeze

  def global?
    privilege_scope == 'global'
  end

  def topic_scoped?
    privilege_scope == 'topic'
  end

  def self.seed_defaults!
    CATALOG.each do |attrs|
      privilege = find_or_initialize_by(key: attrs[:key])
      privilege.assign_attributes(privilege_scope: 'global', **attrs)
      privilege.save!
    end
  end
end
