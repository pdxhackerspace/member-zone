# Keeps a member's issued credentials in step with their standing. When `active` (the
# membership-state projection) turns false, or key access is paused or resumed,
# Credentials::MemberSyncJob revokes, pauses or resumes them at their providers.
# Credentials::ReconcileJob sweeps daily for anything this misses (update_columns, a lost job).
module CredentialLifecycle
  extend ActiveSupport::Concern

  included do
    has_many :credentials, dependent: :destroy
    before_destroy :prevent_destroy_with_live_credentials, prepend: true
    after_update_commit :sync_credentials_on_standing_change
  end

  private

  # Deleting the member would forget credentials that still work elsewhere.
  def prevent_destroy_with_live_credentials
    return unless credentials.live.exists?

    errors.add(:base, 'Revoke this member\'s credentials before deleting them')
    throw :abort
  end

  def sync_credentials_on_standing_change
    return unless saved_change_to_active? || saved_change_to_key_access_paused?
    return unless credentials.exists?(status: %w[active paused])

    Credentials::MemberSyncJob.perform_later(id)
  end
end
