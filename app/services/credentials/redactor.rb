module Credentials
  # Blanks out values that must not reach the run log: the provider's environment variables
  # (its API keys) and, for an issue, the secrets just issued. Values shorter than
  # MINIMUM_LENGTH are left alone — redacting "1" or "true" would shred the text without
  # protecting anything.
  class Redactor
    MINIMUM_LENGTH = 4
    REPLACEMENT = '[REDACTED]'.freeze

    def initialize(values)
      @values = values.map(&:to_s).select { |value| value.length >= MINIMUM_LENGTH }.uniq.sort_by { -it.length }
    end

    def call(text)
      @values.reduce(text.to_s) { |redacted, value| redacted.gsub(value, REPLACEMENT) }
    end
  end
end
