class EmailTemplate
  # Sample values for the credential email templates; see PreviewVariables for why every
  # variable needs one.
  module CredentialPreviewVariables
    module_function

    def all
      {
        credential_name: 'Authentik app password - laptop CLI',
        credential_expires_at: 7.days.from_now.strftime('%B %-d, %Y'),
        credential_names_html: '<ul><li>Authentik app password - laptop CLI</li></ul>',
        credential_names_text: '- Authentik app password - laptop CLI',
        credential_reason: 'your membership is no longer active',
        credentials_url: "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000').chomp('/')}/credentials"
      }
    end
  end
end
