module Journals
  # Renders the `credential` payload that Credential#journal! writes: which provider and
  # label, and why it changed. Never holds a secret; the credential row does not either.
  module CredentialRendering
    def render_credential_change(data)
      content_tag(:div, class: 'small') do
        safe_join([credential_headline(data), credential_details(data)].compact, tag.br)
      end
    end

    def credential_headline(data)
      label = data['label'].presence
      parts = [content_tag(:strong, data['provider'].presence || 'Credential')]
      parts << content_tag(:span, "(#{label})", class: 'text-muted') if label
      safe_join(parts, ' ')
    end

    def credential_details(data)
      parts = []
      parts << "Expires #{data['expires_at']}" if data['expires_at'].present?
      parts << "Reason: #{data['reason']}" if data['reason'].present?
      parts << "Error: #{data['error']}" if data['error'].present?
      return nil if parts.empty?

      content_tag(:span, parts.join(' · '), class: 'text-muted')
    end
  end
end
