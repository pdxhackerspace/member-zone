# A member's own credentials: what they have, requesting a new one, rotating and revoking.
# Administrators with credentials.issue_for_members can issue and rotate on a member's behalf.
#
# An issued secret exists only in the response to the request that issued it: it is rendered
# once with no-store headers, and a repeat of the same request is refused rather than
# issuing a second credential.
class CredentialsController < AuthenticatedController
  before_action :refuse_while_impersonating, only: %i[create rotate]
  before_action :require_request_id, only: %i[create rotate]
  before_action :set_credential, only: %i[revoke rotate]
  before_action :load_target_and_provider, only: %i[new create]

  def index
    @credentials = current_user.credentials.where.not(status: %w[pending failed])
                               .includes(:credential_provider).newest_first
    @providers = requestable_providers
    @denials = @providers.index_with { |provider| denial_reason_for(provider, current_user) }
  end

  def new
    @request_id = SecureRandom.uuid
  end

  def create
    result = Credentials::Issue.call(provider: @provider, user: @member, issued_by: current_user,
                                     label: params[:label], request_id: params[:request_id],
                                     self_service: self_service_request?(@member))
    respond_to_issue(result)
  end

  def revoke
    return deny unless owner? || can?(:'credentials.revoke')

    reason = owner? ? 'revoked_by_member' : 'revoked_by_admin'
    result = Credentials::Revoke.call(@credential, reason: reason, by: true_user)
    if result.ok?
      redirect_back_or_to credentials_path, notice: 'Credential revoked.'
    else
      redirect_back_or_to credentials_path, alert: "Could not revoke it yet: #{result.error} It will be retried."
    end
  end

  def rotate
    return deny unless can_rotate?

    result = Credentials::Rotate.call(@credential, by: current_user, request_id: params[:request_id],
                                                   self_service: self_service_request?(@credential.user))
    respond_to_issue(result)
  end

  private

  def respond_to_issue(result)
    if result.ok?
      render_issued(result)
    elsif result.duplicate
      redirect_to credentials_path, alert: 'That request was already submitted. Credentials are shown only once; ' \
                                           'if you did not save it, revoke it and request a new one.'
    else
      redirect_back_or_to credentials_path, alert: result.error
    end
  end

  # The only place a secret is rendered. Never cached by the browser or an intermediary.
  def render_issued(result)
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
    @credential = result.credential
    @fields = @credential.credential_provider.schema_fields.map do |field|
      field.merge('value' => result.fields.fetch(field['key']))
    end
    @warning = result.warning
    render :issued
  end

  # Who the credential is for and which provider: the signed-in member by default, another
  # member only for someone who may issue on their behalf. Redirects (halting the action)
  # when the request cannot go ahead.
  def load_target_and_provider
    @member = target_member
    return if performed?

    @provider = CredentialProvider.find_by(id: params[:provider_id])
    return redirect_to(credentials_path, alert: 'Choose a credential to request.') unless @provider

    reason = denial_reason
    redirect_to(credentials_path, alert: reason) if reason
  end

  def denial_reason
    denial_reason_for(@provider, @member)
  end

  def denial_reason_for(provider, member)
    if self_service_request?(member)
      provider.self_service_denial_reason(member)
    else
      provider.issue_denial_reason(member)
    end
  end

  # A member acting for themselves is bound by the provider's self-service rule. Someone who
  # may issue on members' behalf is not, including when the member is themselves — otherwise
  # an administrator could never hold a credential from an administrator-only provider.
  def self_service_request?(member)
    member == current_user && !can?(:'credentials.issue_for_members')
  end

  # What the signed-in member can see to request: self-service providers, plus the
  # administrator-only ones for someone who may issue them.
  def requestable_providers
    providers = CredentialProvider.enabled.ordered
    can?(:'credentials.issue_for_members') ? providers : providers.self_service
  end

  def target_member
    return current_user if params[:member_email].blank? && params[:user_id].to_s.in?(['', current_user.id.to_s])
    return deny unless can?(:'credentials.issue_for_members')

    member = find_requested_member
    return member if member

    redirect_to issued_credentials_path, alert: 'No member found. Enter the full email address they signed up with.'
  end

  def find_requested_member
    return User.by_any_email(params[:member_email].to_s.strip).first if params[:member_email].present?

    User.find_by(id: params[:user_id])
  end

  # Every issue carries the id the form was rendered with; it is what makes a replayed or
  # double-submitted request issue once.
  def require_request_id
    return if Credential::UUID_FORMAT.match?(params[:request_id].to_s)

    redirect_to credentials_path, alert: 'That request was not valid. Please start again.'
  end

  def refuse_while_impersonating
    return unless impersonating?

    redirect_to credentials_path, alert: 'Credentials cannot be issued or rotated while impersonating a member.'
  end

  def set_credential
    @credential = Credential.includes(:credential_provider).find(params[:id])
  end

  def owner?
    @credential.user_id == current_user.id
  end

  def can_rotate?
    (owner? && @credential.credential_provider.self_service?) || can?(:'credentials.issue_for_members')
  end

  def deny
    redirect_to user_path(current_user), alert: 'You do not have access to that section.'
  end
end
