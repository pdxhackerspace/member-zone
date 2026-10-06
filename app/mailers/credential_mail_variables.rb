# Template variables for the credential emails, built from the plain values the mailer is
# queued with (names, a date, a reason) so a queued message can be regenerated later. Nothing
# here ever sees a secret.
module CredentialMailVariables
  KEYS = %i[credential_name credential_expires_at credential_names credential_reason].freeze

  module_function

  def applicable?(extra_args)
    KEYS.any? { |key| extra_args.key?(key) }
  end

  def call(extra_args)
    names = Array(extra_args[:credential_names]).map(&:to_s)
    vars = { credentials_url: credentials_url }
    vars[:credential_name] = extra_args[:credential_name].to_s if extra_args.key?(:credential_name)
    vars[:credential_expires_at] = extra_args[:credential_expires_at].to_s if extra_args.key?(:credential_expires_at)
    vars[:credential_reason] = extra_args[:credential_reason].to_s if extra_args.key?(:credential_reason)
    vars.merge!(credential_names_html: html_list(names), credential_names_text: text_list(names)) if names.any?
    vars
  end

  def credentials_url
    "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000').chomp('/')}/credentials"
  end

  def html_list(names)
    "<ul>#{names.map { |name| "<li>#{ERB::Util.html_escape(name)}</li>" }.join}</ul>"
  end

  def text_list(names)
    names.map { |name| "- #{name}" }.join("\n")
  end
end
