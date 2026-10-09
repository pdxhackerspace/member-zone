# Reads the cached `describe` output of a credential provider's program: which fields an
# issued credential has, which of them are secret, and which actions the program supports.
# Credentials::Protocol.describe is what validates and normalizes it before it is stored.
module CredentialProviderSchema
  extend ActiveSupport::Concern

  REQUIRED_ACTIONS = %w[issue revoke health].freeze

  def schema_fields
    Array(schema&.dig('fields'))
  end

  def schema_field(key)
    schema_fields.find { |field| field['key'] == key.to_s }
  end

  def schema_actions
    Array(schema&.dig('actions'))
  end

  def schema_ready?
    schema_fields.any? && (REQUIRED_ACTIONS - schema_actions).empty?
  end

  def supports?(action)
    schema_actions.include?(action.to_s)
  end

  # Pausing needs both halves; Credentials::Protocol refuses a schema that lists only one.
  def supports_pause?
    supports?('pause') && supports?('resume')
  end

  def schema_display_name
    schema&.dig('name').presence || name
  end
end
