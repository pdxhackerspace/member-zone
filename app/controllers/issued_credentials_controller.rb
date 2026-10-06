# Every credential issued to every member, for the administrators who look after them.
class IssuedCredentialsController < AuthenticatedController
  PER_PAGE = 50
  EXPIRING_WITHIN = 14.days
  STATUS_FILTERS = (Credential::STATUSES - %w[pending]).freeze

  before_action -> { require_privilege!(:'credentials.view_all') }

  def index
    @providers = CredentialProvider.ordered
    @provider = @providers.find { |provider| provider.id.to_s == params[:provider_id] }
    @status = params[:status] if STATUS_FILTERS.include?(params[:status])
    @expiring = params[:expiring] == '1'
    @member = User.find_by(id: params[:user_id]) if params[:user_id].present?
    load_counts
    @pagy, @credentials = pagy(filtered.includes(:credential_provider, :user, :issued_by).newest_first,
                               limit: PER_PAGE)
  end

  private

  def filtered
    scope = Credential.where.not(status: 'pending')
    scope = scope.where(credential_provider_id: @provider.id) if @provider
    scope = scope.where(status: @status) if @status
    scope = scope.where(user_id: @member.id) if @member
    scope = scope.expirable.where(expires_at: Time.current..EXPIRING_WITHIN.from_now) if @expiring
    scope
  end

  def load_counts
    base = Credential.where.not(status: 'pending')
    @total_count = base.count
    @live_count = base.live.count
    @attention_count = Credential.revoke_failed.count
    @expiring_count = Credential.expirable.where(expires_at: Time.current..EXPIRING_WITHIN.from_now).count
  end
end
