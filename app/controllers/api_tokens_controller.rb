# A member's own API tokens: creating one, and extending, suspending, resuming, and revoking
# them. Token managers (api.tokens.manage) may also act on anyone's token from here, which is
# where the settings page's buttons post.
class ApiTokensController < AuthenticatedController
  include ApiTokenIssuing

  LIFECYCLE_NOTICES = {
    'renew' => 'Token extended. It keeps the same secret.',
    'suspend' => 'Token suspended. It is refused until you resume it.',
    'resume' => 'Token resumed.',
    'revoke' => 'Token revoked. It can never be used again.'
  }.freeze

  before_action :refuse_while_impersonating, only: %i[create renew suspend resume revoke]
  before_action :set_api_token, only: %i[renew suspend resume revoke]

  def index
    @api_tokens = current_user.api_tokens.includes(:contact_user).newest_first
    @max_lifetime_days = DefaultSetting.instance.api_token_max_lifetime_days
  end

  def new
    @api_token = current_user.api_tokens.build
    load_scope_options
  end

  def create
    @api_token = current_user.api_tokens.build(api_token_params)
    @api_token.created_by = current_user
    @api_token.scopes = requested_scopes

    if @api_token.save
      @api_token.journal!('api_token_created', actor: current_user)
      render_issued(@api_token)
    else
      load_scope_options
      render :new, status: :unprocessable_content
    end
  end

  def renew
    change_token { @api_token.extend!(by: true_user) }
  end

  def suspend
    change_token { @api_token.suspend!(by: true_user, reason: params[:reason]) }
  end

  def resume
    change_token { @api_token.resume!(by: true_user) }
  end

  def revoke
    change_token { @api_token.revoke!(by: true_user, reason: params[:reason]) }
  end

  private

  def change_token
    yield
    redirect_back_or_to lifecycle_return_path, notice: LIFECYCLE_NOTICES.fetch(action_name)
  rescue ActiveRecord::RecordInvalid => e
    redirect_back_or_to lifecycle_return_path, alert: e.record.errors.full_messages.to_sentence
  end

  def set_api_token
    scope = can?(:'api.tokens.manage') ? ApiToken.all : current_user.api_tokens
    @api_token = scope.find(params[:id])
  end

  def load_scope_options
    @scope_options = ApiToken.grantable_scopes(granter: current_user, holder: current_user)
  end

  def api_token_params
    params.expect(api_token: %i[name description])
  end

  def lifecycle_return_path
    api_tokens_path
  end
end
