class EmailTemplate
  # Sample values for the API token templates; see PreviewVariables for why every variable needs one.
  module ApiTokenPreviewVariables
    module_function

    def all
      {
        api_token_name: 'Front desk kiosk',
        api_token_hint: 'x9Qa',
        api_token_holder: 'Front Desk Kiosk',
        api_token_expires_at: 'March 29, 2027',
        api_tokens_url: "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000')}/settings/api_tokens"
      }
    end
  end
end
