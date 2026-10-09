module Credentials
  # What is kept of an issued credential's fields. A non-secret field is kept whole. A secret
  # field keeps its first and last four characters so a member can match it against what they
  # saved — unless it is shorter than MINIMUM_HINTED_LENGTH, where eight characters would be
  # most of it, in which case nothing of it is kept.
  module FieldHints
    HINT_LENGTH = 4
    MINIMUM_HINTED_LENGTH = 12
    MASK = '••••'.freeze

    module_function

    def call(fields, schema_fields)
      schema_fields.each_with_object({}) do |field, hints|
        value = fields.fetch(field['key'])
        hints[field['key']] = field['secret'] ? secret_hint(value) : { 'value' => value }
      end
    end

    def secret_hint(value)
      return {} if value.length < MINIMUM_HINTED_LENGTH

      { 'prefix' => value[0, HINT_LENGTH], 'suffix' => value[-HINT_LENGTH, HINT_LENGTH] }
    end

    def display(hint)
      hint = hint.to_h
      return hint['value'] if hint.key?('value')
      return MASK if hint['prefix'].blank?

      "#{hint['prefix']}…#{hint['suffix']}"
    end
  end
end
