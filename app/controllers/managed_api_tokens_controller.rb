# Settings → API tokens: every token, for holders of api.tokens.manage. Creates tokens for
# service accounts, reassigns the contact who is reminded before a token expires, and sets the
# maximum lifetime. Extending, suspending, resuming, and revoking post to ApiTokensController.
class ManagedApiTokensController < AuthenticatedController
  include Pagy::Method
  include ApiTokenIssuing

  EXPIRING_WINDOW = 30.days
  FILTERS = %w[active expiring suspended expired revoked no_contact].freeze

  before_action -> { require_privilege!(:'api.tokens.manage') }
  before_action :refuse_while_impersonating, only: %i[create update lifetime]
  before_action :set_api_token, only: %i[edit update]

  def index
    tokens = ApiToken.includes(:user, :contact_user, :created_by).newest_first
    tokens = tokens.joins(:user).where(users: { service_account: params[:kind] == 'service' }) if kind_filter?
    @filter = params[:filter].presence_in(FILTERS)
    @counts = filter_counts
    @pagy, @api_tokens = pagy(apply_filter(tokens), limit: 50)
    @default_setting = DefaultSetting.instance
  end

  def new
    @api_token = ApiToken.new(contact_user: current_user)
    load_form_options
  end

  def edit
    load_form_options
  end

  def create
    @api_token = ApiToken.new(api_token_params)
    @api_token.user = User.service_accounts.find_by(id: params.dig(:api_token, :user_id))
    @api_token.created_by = current_user
    @api_token.scopes = requested_scopes

    if @api_token.save
      @api_token.journal!('api_token_created', actor: current_user)
      render_issued(@api_token)
    else
      load_form_options
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @api_token.update(api_token_params)
      redirect_to managed_api_tokens_path, notice: 'Token updated.'
    else
      load_form_options
      render :edit, status: :unprocessable_content
    end
  end

  def lifetime
    setting = DefaultSetting.instance
    if setting.update(api_token_max_lifetime_days: params[:api_token_max_lifetime_days])
      redirect_to managed_api_tokens_path, notice: 'Maximum token lifetime updated. Existing tokens keep their expiry.'
    else
      redirect_to managed_api_tokens_path, alert: setting.errors.full_messages.to_sentence
    end
  end

  private

  def set_api_token
    @api_token = ApiToken.find(params[:id])
  end

  def load_form_options
    @service_accounts = User.service_accounts.ordered_by_display_name
    @contacts = User.non_service_accounts.active.ordered_by_display_name
    @scope_options = ApiToken.grantable_scopes(granter: current_user)
  end

  def api_token_params
    params.expect(api_token: %i[name description contact_user_id])
  end

  def kind_filter?
    params[:kind].in?(%w[personal service])
  end

  def apply_filter(tokens)
    now = Time.current
    case @filter
    when 'active' then tokens.usable(now)
    when 'expiring' then tokens.usable(now).where(expires_at: ..(now + EXPIRING_WINDOW))
    when 'suspended' then tokens.suspended
    when 'expired' then tokens.expired(now)
    when 'revoked' then tokens.revoked
    when 'no_contact' then tokens.where(id: tokens_without_contact)
    else tokens
    end
  end

  # Tokens whose expiry warning cannot reach anyone on the token, by the same rule the reminder
  # uses. Worked out in Ruby because that rule (blocked recipients, service-account contacts)
  # does not reduce to a query; the table holds a handful of rows per member at most.
  def tokens_without_contact
    @tokens_without_contact ||= ApiToken.not_revoked.includes(:contact_user).select do |token|
      Reminders::ApiTokenExpiryEligibility.contact_unreachable?(token)
    end.map(&:id)
  end

  def filter_counts
    now = Time.current
    {
      'active' => ApiToken.usable(now).count,
      'expiring' => ApiToken.usable(now).where(expires_at: ..(now + EXPIRING_WINDOW)).count,
      'suspended' => ApiToken.suspended.count,
      'expired' => ApiToken.expired(now).count,
      'revoked' => ApiToken.revoked.count,
      'no_contact' => tokens_without_contact.size
    }
  end

  def lifecycle_return_path
    managed_api_tokens_path
  end
end
