# What a member's own token page and the token managers' page share: showing a new token's
# secret exactly once, and refusing to touch tokens while impersonating.
#
# Including controllers refuse their changing actions while impersonating. A token changed by an
# administrator viewing as a member would be journaled as the administrator's act on the member's
# account and look like the member's own, and a token minted that way would hand the
# administrator a credential that outlives the impersonation.
module ApiTokenIssuing
  extend ActiveSupport::Concern

  private

  # The only place a token's secret is rendered. Never cached by the browser or an intermediary.
  def render_issued(token)
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
    @api_token = token
    render 'api_tokens/issued'
  end

  def refuse_while_impersonating
    return unless impersonating?

    redirect_to lifecycle_return_path, alert: 'API tokens cannot be created or changed while impersonating a member.'
  end

  def requested_scopes
    Array(params.dig(:api_token, :scopes)).compact_blank
  end
end
