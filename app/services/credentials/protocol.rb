module Credentials
  # Validates what a credential provider's program prints for each action. Every program
  # speaks JSON on stdout; docs/credentials.md is the spec.
  #
  # Error messages name keys and describe shapes but never repeat a value: the output being
  # checked may be an issued secret, and these messages end up in the run log and in Sentry.
  module Protocol
    VERSION = 1
    KNOWN_ACTIONS = %w[describe health issue revoke pause resume].freeze
    FIELD_KEY = /\A[a-z][a-z0-9_]{0,63}\z/

    class Error < StandardError; end

    module_function

    def parse_object(stdout)
      parsed = JSON.parse(stdout.to_s)
      raise Error, 'output is not a JSON object' unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise Error, 'output is not valid JSON'
    end

    def describe(stdout)
      data = parse_object(stdout)
      raise Error, "protocol must be #{VERSION}" unless data['protocol'] == VERSION

      {
        'protocol' => VERSION,
        'name' => optional_string(data, 'name'),
        'description' => optional_string(data, 'description'),
        'fields' => describe_fields(data['fields']),
        'actions' => describe_actions(data['actions'])
      }.compact
    end

    def health(stdout)
      data = parse_object(stdout)
      raise Error, 'ok must be true or false' unless [true, false].include?(data['ok'])

      { ok: data['ok'], message: optional_string(data, 'message') }
    end

    # Returns the issued fields in schema order, plus the program's handle for the credential
    # and its expiry. +external_id+ is pulled out first so a caller can still revoke a
    # credential whose fields came back malformed.
    def issue(stdout, schema_fields)
      data = parse_object(stdout)
      { external_id: issue_external_id(data), fields: issue_fields(data['fields'], schema_fields),
        expires_at: issue_expires_at(data['expires_at']) }
    end

    # Best effort for cleanup: the handle from output that otherwise failed validation.
    def external_id_from(stdout)
      issue_external_id(parse_object(stdout))
    rescue Error
      nil
    end

    def describe_fields(fields)
      raise Error, 'fields must be a non-empty array' unless fields.is_a?(Array) && fields.any?

      normalized = fields.map { |field| describe_field(field) }
      duplicates = normalized.pluck('key').tally.select { |_key, count| count > 1 }.keys
      raise Error, "duplicate field #{duplicates.first}" if duplicates.any?

      normalized
    end

    def describe_field(field)
      raise Error, 'each field must be an object' unless field.is_a?(Hash)

      key = field['key']
      raise Error, 'field keys must be lowercase letters, digits and underscores' unless key.is_a?(String) &&
                                                                                         FIELD_KEY.match?(key)

      secret = field.fetch('secret', true)
      raise Error, "field #{key}: secret must be true or false" unless [true, false].include?(secret)

      { 'key' => key, 'label' => optional_string(field, 'label') || key.humanize, 'secret' => secret }
    end

    def describe_actions(actions)
      raise Error, 'actions must be an array of strings' unless actions.is_a?(Array) && actions.all?(String)

      unknown = actions - KNOWN_ACTIONS
      raise Error, "unknown action #{unknown.first}" if unknown.any?

      missing = CredentialProviderSchema::REQUIRED_ACTIONS - actions
      raise Error, "actions must include #{missing.join(', ')}" if missing.any?
      raise Error, 'pause and resume must be supported together' if actions.include?('pause') ^
                                                                    actions.include?('resume')

      actions.uniq
    end

    def issue_external_id(data)
      id = data['external_id']
      id = id.to_s if id.is_a?(Integer)
      raise Error, 'external_id must be a non-empty string' unless id.is_a?(String) && id.strip.present?
      raise Error, 'external_id is too long' if id.length > 255

      id.strip
    end

    def issue_fields(fields, schema_fields)
      raise Error, 'fields must be an object' unless fields.is_a?(Hash)

      expected = schema_fields.pluck('key')
      missing = expected - fields.keys
      extra = fields.keys - expected
      raise Error, "missing field #{missing.first} declared by describe" if missing.any?
      # Names the count, not the key: an undeclared key is output like any other and may be a secret.
      raise Error, "#{extra.size} unexpected field(s) not declared by describe" if extra.any?

      expected.index_with do |key|
        value = fields[key]
        raise Error, "field #{key} must be a non-empty string" unless value.is_a?(String) && value.present?

        value
      end
    end

    def issue_expires_at(value)
      return nil if value.nil?
      raise Error, 'expires_at must be an ISO 8601 string' unless value.is_a?(String)

      time = Time.iso8601(value)
      raise Error, 'expires_at is in the past' if time <= Time.current

      time
    rescue ArgumentError
      raise Error, 'expires_at must be an ISO 8601 string'
    end

    def optional_string(data, key)
      value = data[key]
      return nil if value.nil?
      raise Error, "#{key} must be a string" unless value.is_a?(String)

      value.strip.presence&.truncate(500)
    end
  end
end
