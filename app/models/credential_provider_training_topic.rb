# A training topic a member must hold before a credential provider will issue to them.
class CredentialProviderTrainingTopic < ApplicationRecord
  belongs_to :credential_provider
  belongs_to :training_topic

  validates :training_topic_id, uniqueness: { scope: :credential_provider_id }
end
