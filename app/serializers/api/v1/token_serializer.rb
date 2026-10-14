module Api
  module V1
    # A token describing itself. Never includes the secret, which is not stored.
    module TokenSerializer
      module_function

      def call(token)
        {
          id: token.id,
          name: token.name,
          hint: token.token_hint,
          kind: token.service? ? 'service' : 'personal',
          scopes: token.scopes,
          effective_scopes: token.scopes.select { |key| token.allows?(key) },
          expires_at: token.expires_at.iso8601,
          holder: MemberSerializer.call(token.user)
        }
      end
    end
  end
end
