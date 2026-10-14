# Template variables for the API token expiry warning. Never includes the secret, which is not
# stored anywhere to include.
module ApiTokenMailVariables
  module_function

  def call(token, recipient:)
    {
      api_token_name: token.name,
      api_token_hint: token.token_hint.to_s,
      api_token_holder: token.user.display_name,
      api_token_expires_at: token.expires_at.in_time_zone.strftime('%B %-d, %Y'),
      api_tokens_url: tokens_url(token, recipient)
    }
  end

  # The holder and the contact extend a token from their own tokens page; a token manager warned
  # in their place uses the settings page.
  def tokens_url(token, recipient)
    base = ENV.fetch('APP_BASE_URL', 'http://localhost:3000').chomp('/')
    answerable = recipient.id.in?([token.user_id, token.contact_user_id])
    answerable ? "#{base}/api_tokens" : "#{base}/settings/api_tokens"
  end
end
