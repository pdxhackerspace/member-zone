# One call to a credential provider's program: which action, how it ended, and what it wrote
# to stderr (with the provider's environment values and any issued secret blanked out). An
# issued secret is never recorded here — stdout from `issue` is not kept.
class CredentialRun < ApplicationRecord
  STATUSES = %w[running success failed].freeze

  belongs_to :credential_provider
  belongs_to :credential, optional: true

  validates :action, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def status_dot_class
    { 'success' => 'success', 'failed' => 'danger', 'running' => 'warning' }.fetch(status, 'muted')
  end
end
