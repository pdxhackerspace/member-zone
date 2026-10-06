require 'test_helper'

class CredentialsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  SECRET = 'abcd-secret-value-wxyz'.freeze

  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @provider = create_credential_provider(name: 'Apps')
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  def request_credential(provider: @provider, request_id: SecureRandom.uuid, **extra)
    post credentials_path,
         params: { provider_id: provider.id, request_id: request_id, label: 'laptop CLI' }.merge(extra)
  end

  # Captures everything Rails logs while the block runs.
  def capture_log
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(logger)
  end

  def impersonate(member)
    admin = sign_in_as_admin
    post impersonate_user_path(user_id: member.id)
    assert_equal member.id, session[:impersonated_user_id]
    admin
  end

  # --- Access ---

  test 'every action needs a signed-in member' do
    get credentials_path
    assert_redirected_to login_path
    get new_credential_path(provider_id: @provider.id)
    assert_redirected_to login_path
    post credentials_path, params: { provider_id: @provider.id }
    assert_redirected_to login_path
    assert_equal 0, Credential.count
  end

  test 'a plain member can see the page and request without any privilege' do
    sign_in_as_plain_member
    get credentials_path
    assert_response :success
  end

  # --- Index ---

  test 'index shows only my own credentials, with hints and no secrets' do
    me = sign_in_as_plain_member
    mine = create_credential(provider: @provider, user: me, label: 'my laptop')
    create_credential(provider: @provider, user: create_member, label: 'someone elses')

    get credentials_path

    assert_response :success
    assert_select 'td', text: /my laptop/
    assert_select 'td', text: /someone elses/, count: 0
    assert_select 'code', text: 'abcd…wxyz'
    assert_select 'code', text: mine.field_hints['client_id']['value']
    assert_not_includes response.body, SECRET
  end

  test 'index leaves out pending and failed rows' do
    me = sign_in_as_plain_member
    create_credential(provider: @provider, user: me, status: 'pending', label: 'in flight')
    create_credential(provider: @provider, user: me, status: 'failed', label: 'broke')

    get credentials_path

    assert_select 'td', text: /in flight/, count: 0
    assert_select 'td', text: /broke/, count: 0
  end

  test 'index shows revoked credentials without revoke buttons and the reason' do
    me = sign_in_as_plain_member
    gone = create_credential(provider: @provider, user: me, status: 'revoked', revocation_reason: 'member_inactive')

    get credentials_path

    assert_select 'td', text: /Membership no longer active/
    assert_select 'form[action=?]', revoke_credential_path(gone), count: 0
  end

  test 'index offers revoke and replace for an active credential' do
    me = sign_in_as_plain_member
    mine = create_credential(provider: @provider, user: me)

    get credentials_path

    assert_select 'form[action=?]', revoke_credential_path(mine)
    assert_select 'form[action=?][data-turbo=false]', rotate_credential_path(mine)
  end

  test 'index does not offer replace for an administrator-only provider' do
    provider = create_credential_provider(self_service: false)
    me = sign_in_as_plain_member
    mine = create_credential(provider: provider, user: me)

    get credentials_path

    assert_select 'form[action=?]', rotate_credential_path(mine), count: 0
    assert_select 'form[action=?]', revoke_credential_path(mine)
  end

  test 'index lists providers a member can request from, and why not for the rest' do
    create_credential_provider(name: 'Needs training').tap do |provider|
      provider.required_training_topics = [TrainingTopic.create!(name: "Welding #{SecureRandom.hex(3)}")]
    end
    create_credential_provider(name: 'Staff only', self_service: false)
    create_credential_provider(name: 'Turned off', enabled: false)
    sign_in_as_plain_member

    get credentials_path

    assert_select 'a.action-card[href=?]', new_credential_path(provider_id: @provider.id)
    assert_select '.action-card.disabled', text: /Requires training in Welding/
    assert_select '.action-card', text: /Staff only/, count: 0
    assert_select '.action-card', text: /Turned off/, count: 0
  end

  test 'index with nothing available says so calmly' do
    CredentialProvider.update_all(enabled: false)
    sign_in_as_plain_member

    get credentials_path

    assert_select '.card-body', text: /Nothing is available to request right now/
    assert_select '.card-body', text: /don't have any credentials yet/
  end

  test 'a member who is no longer active sees why they cannot request' do
    me = sign_in_as_plain_member
    me.ban!

    get credentials_path

    assert_select '.action-card.disabled', text: /Only active members/
  end

  # --- New ---

  test 'new shows the form with a request id, a full-page post and the show-once warning' do
    sign_in_as_plain_member

    get new_credential_path(provider_id: @provider.id)

    assert_response :success
    assert_select 'form[action=?][data-turbo=false]', credentials_path
    assert_select 'input[name=provider_id][value=?]', @provider.id.to_s
    assert_select 'input[name=request_id]' do |inputs|
      assert_match Credential::UUID_FORMAT, inputs.first['value']
    end
    assert_select 'input[name=label]'
    assert_select '.alert-warning', text: /shown\s+once/
  end

  test 'each visit to new gets a fresh request id' do
    sign_in_as_plain_member

    get new_credential_path(provider_id: @provider.id)
    first = css_select('input[name=request_id]').first['value']
    get new_credential_path(provider_id: @provider.id)

    assert_not_equal first, css_select('input[name=request_id]').first['value']
  end

  test 'new refuses a provider the member cannot use, with the reason' do
    sign_in_as_plain_member
    staff_only = create_credential_provider(self_service: false)

    get new_credential_path(provider_id: staff_only.id)

    assert_redirected_to credentials_path
    assert_match(/administrator/, flash[:alert])
  end

  test 'new without a provider goes back to the list' do
    sign_in_as_plain_member

    get new_credential_path

    assert_redirected_to credentials_path
    get new_credential_path(provider_id: 0)
    assert_redirected_to credentials_path
  end

  # --- Create ---

  test 'create issues the credential and shows the secret once' do
    me = sign_in_as_plain_member

    assert_difference -> { Credential.where(user: me, status: 'active').count } => 1 do
      request_credential
    end

    assert_response :success
    assert_template_rendered_issued
    assert_includes response.body, SECRET
    assert_select 'input[readonly][value=?]', SECRET
    assert_select 'input[readonly][value^=client-]'
    assert_select 'a[href=?]', credentials_path, text: "I've saved this"
    assert_select 'button', text: 'Copy', count: 2
  end

  def assert_template_rendered_issued
    assert_select 'h1', text: 'Your new credential'
  end

  test 'the response carries no-store headers' do
    sign_in_as_plain_member

    request_credential

    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-cache', response.headers['Pragma']
    assert_select 'meta[name="turbo-cache-control"][content="no-cache"]'
  end

  test 'the secret is in the create response and nowhere else' do
    me = sign_in_as_plain_member
    request_credential
    assert_includes response.body, SECRET

    get credentials_path
    assert_response :success
    assert_not_includes response.body, SECRET
    assert_select 'code', text: 'abcd…wxyz'

    get new_credential_path(provider_id: @provider.id)
    assert_not_includes response.body, SECRET
    assert_equal 1, me.credentials.count
  end

  test 'the secret is never written to the database or the log' do
    sign_in_as_plain_member

    log = capture_log { request_credential }

    assert_includes response.body, SECRET
    assert_not_includes log, SECRET
    assert_secret_not_stored(SECRET)
  end

  test 'a replayed post does not issue twice and does not show the secret again' do
    me = sign_in_as_plain_member
    request_id = SecureRandom.uuid
    request_credential(request_id: request_id)
    assert_includes response.body, SECRET

    assert_no_difference -> { Credential.count } do
      request_credential(request_id: request_id)
    end

    assert_redirected_to credentials_path
    assert_match(/shown only once/, flash[:alert])
    follow_redirect!
    assert_not_includes response.body, SECRET
    assert_equal(1, credential_calls.count { |line| line.start_with?('issue') })
    assert_equal 1, me.credentials.count
  end

  test 'create without a valid request id issues nothing' do
    sign_in_as_plain_member

    assert_no_difference -> { Credential.count } do
      request_credential(request_id: 'nope')
      assert_redirected_to credentials_path
      assert_match(/not valid/, flash[:alert])
      post credentials_path, params: { provider_id: @provider.id }
      assert_redirected_to credentials_path
    end
    assert_empty credential_calls
  end

  test 'create records the member as issuer and keeps the label' do
    me = sign_in_as_plain_member

    request_credential

    credential = me.credentials.last
    assert_equal me, credential.issued_by
    assert_equal 'laptop CLI', credential.label
    assert_equal({ 'prefix' => 'abcd', 'suffix' => 'wxyz' }, credential.field_hints['client_secret'])
  end

  test 'create refuses what the rules refuse, with the reason and without running the program' do
    me = sign_in_as_plain_member
    me.ban!

    assert_no_difference -> { Credential.count } do
      request_credential
    end

    assert_redirected_to credentials_path
    assert_match(/active members/, flash[:alert])
    assert_empty credential_calls
  end

  test 'create refuses a provider that is disabled, unhealthy, or at the limit' do
    me = sign_in_as_plain_member
    disabled = create_credential_provider(enabled: false)
    unhealthy = create_credential_provider(health: 'unhealthy')
    full = create_credential_provider(max_per_member: 1)
    create_credential(provider: full, user: me)

    [disabled, unhealthy, full].each do |provider|
      assert_no_difference -> { Credential.count } do
        request_credential(provider: provider)
      end
      assert_redirected_to credentials_path
    end
  end

  test 'create refuses a provider that requires training the member lacks' do
    sign_in_as_plain_member
    @provider.required_training_topics = [TrainingTopic.create!(name: "Lathe #{SecureRandom.hex(3)}")]

    assert_no_difference -> { Credential.count } do
      request_credential
    end
    assert_match(/Requires training/, flash[:alert])
  end

  test 'a failing program is reported without detail and without a secret' do
    provider = create_credential_provider(env: { FAIL_ISSUE: '1' })
    sign_in_as_plain_member

    request_credential(provider: provider)

    assert_redirected_to credentials_path
    assert_equal Credentials::Issue::GENERIC_FAILURE, flash[:alert]
    assert_not_includes flash[:alert], 'simulated'
  end

  test 'a failed issue does not block a fresh try' do
    provider = create_credential_provider(env: { FAIL_ISSUE: '1' })
    me = sign_in_as_plain_member
    request_credential(provider: provider)

    provider.update!(environment_variables: "STATE_DIR=#{credential_state_dir}")
    request_credential(provider: provider)

    assert_response :success
    assert_equal 1, me.credentials.where(status: 'active').count
  end

  # --- Impersonation ---

  test 'issuing is refused while impersonating a member' do
    member = create_member
    impersonate(member)

    assert_no_difference -> { Credential.count } do
      request_credential
    end

    assert_redirected_to credentials_path
    assert_match(/impersonating/, flash[:alert])
    assert_empty credential_calls
  end

  test 'the form can be viewed while impersonating but not submitted' do
    impersonate(create_member)

    get new_credential_path(provider_id: @provider.id)

    assert_response :success
  end

  test 'rotating is refused while impersonating' do
    member = create_member
    mine = create_credential(provider: @provider, user: member)
    impersonate(member)

    post rotate_credential_path(mine), params: { request_id: SecureRandom.uuid }

    assert_redirected_to credentials_path
    assert_match(/impersonating/, flash[:alert])
    assert_equal 'active', mine.reload.status
    assert_equal 1, Credential.where(user: member).count
  end

  test 'impersonating a member grants none of the admin rights over their credentials' do
    member = create_member
    other = create_credential(provider: @provider, user: create_member)
    impersonate(member)

    post revoke_credential_path(other)

    assert_equal 'active', other.reload.status
  end

  # --- Revoke ---

  test 'a member revokes their own credential' do
    me = sign_in_as_plain_member
    mine = create_credential(provider: @provider, user: me)

    post revoke_credential_path(mine)

    assert_redirected_to credentials_path
    assert_equal 'Credential revoked.', flash[:notice]
    mine.reload
    assert_equal 'revoked', mine.status
    assert_equal 'revoked_by_member', mine.revocation_reason
    assert_equal me, mine.revoked_by
  end

  test 'a member cannot revoke someone elses credential' do
    sign_in_as_plain_member
    theirs = create_credential(provider: @provider, user: create_member)

    post revoke_credential_path(theirs)

    assert_response :redirect
    assert_equal 'active', theirs.reload.status
    assert_empty credential_calls
  end

  test 'credentials.revoke lets someone revoke another members credential' do
    me = sign_in_as_plain_member
    grant_privileges(me, 'credentials.revoke')
    sign_in_as_plain_member
    theirs = create_credential(provider: @provider, user: create_member)

    post revoke_credential_path(theirs)

    theirs.reload
    assert_equal 'revoked', theirs.status
    assert_equal 'revoked_by_admin', theirs.revocation_reason
    assert_equal me, theirs.revoked_by
  end

  test 'revoke reports a failure and keeps the credential for retry' do
    provider = create_credential_provider(env: { FAIL_REVOKE: '1' })
    me = sign_in_as_plain_member
    mine = create_credential(provider: provider, user: me)

    post revoke_credential_path(mine)

    assert_redirected_to credentials_path
    assert_match(/Could not revoke it yet/, flash[:alert])
    assert_equal 'revoke_failed', mine.reload.status
  end

  test 'revoke is allowed while impersonating and is recorded against the real admin' do
    member = create_member
    mine = create_credential(provider: @provider, user: member)
    admin = impersonate(member)

    post revoke_credential_path(mine)

    mine.reload
    assert_equal 'revoked', mine.status
    assert_equal admin, mine.revoked_by, 'the admin, not the member, is on record'
  end

  # --- Rotate ---

  test 'a member replaces their own credential and sees the new secret once' do
    me = sign_in_as_plain_member
    old = create_credential(provider: @provider, user: me, label: 'laptop CLI')

    post rotate_credential_path(old), params: { request_id: SecureRandom.uuid }

    assert_response :success
    assert_includes response.body, SECRET
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'revoked', old.reload.status
    assert_equal 'rotated', old.revocation_reason
    replacement = me.credentials.where(rotated_from: old).first
    assert_equal 'active', replacement.status
    assert_equal 'laptop CLI', replacement.label
    assert_secret_not_stored(SECRET)
  end

  test 'replacing at the per-member limit works' do
    provider = create_credential_provider(max_per_member: 1)
    me = sign_in_as_plain_member
    old = create_credential(provider: provider, user: me)

    post rotate_credential_path(old), params: { request_id: SecureRandom.uuid }

    assert_response :success
    assert_equal 'revoked', old.reload.status
  end

  test 'a replayed rotate does not rotate twice' do
    me = sign_in_as_plain_member
    old = create_credential(provider: @provider, user: me)
    request_id = SecureRandom.uuid
    post rotate_credential_path(old), params: { request_id: request_id }

    assert_no_difference -> { Credential.count } do
      post rotate_credential_path(old), params: { request_id: request_id }
    end
    assert_response :redirect
  end

  test 'a member cannot rotate someone elses credential' do
    sign_in_as_plain_member
    theirs = create_credential(provider: @provider, user: create_member)

    assert_no_difference -> { Credential.count } do
      post rotate_credential_path(theirs), params: { request_id: SecureRandom.uuid }
    end
    assert_response :redirect
    assert_equal 'active', theirs.reload.status
  end

  test 'a member cannot rotate a credential from an administrator-only provider' do
    provider = create_credential_provider(self_service: false)
    me = sign_in_as_plain_member
    mine = create_credential(provider: provider, user: me)

    assert_no_difference -> { Credential.count } do
      post rotate_credential_path(mine), params: { request_id: SecureRandom.uuid }
    end
    assert_equal 'active', mine.reload.status
  end

  test 'credentials.issue_for_members lets someone rotate for a member, and they see the secret' do
    me = sign_in_as_plain_member
    grant_privileges(me, 'credentials.issue_for_members')
    sign_in_as_plain_member
    theirs = create_credential(provider: @provider, user: create_member)

    post rotate_credential_path(theirs), params: { request_id: SecureRandom.uuid }

    assert_response :success
    assert_includes response.body, SECRET
    assert_equal me, Credential.find_by(rotated_from: theirs).issued_by
  end

  # --- Issuing for a member ---

  test 'issuing for another member needs credentials.issue_for_members, both ways' do
    sign_in_as_plain_member
    target = create_member

    assert_no_difference -> { Credential.count } do
      request_credential(user_id: target.id)
      assert_response :redirect
      get new_credential_path(provider_id: @provider.id, user_id: target.id)
      assert_response :redirect
      get new_credential_path(provider_id: @provider.id, member_email: target.email)
      assert_response :redirect
    end
  end

  test 'someone with issue_for_members issues for a member and the issuer sees the secret' do
    me = sign_in_as_plain_member
    grant_privileges(me, 'credentials.issue_for_members')
    sign_in_as_plain_member
    target = create_member

    get new_credential_path(provider_id: @provider.id, member_email: target.email)
    assert_response :success
    assert_select 'input[name=user_id][value=?]', target.id.to_s
    assert_select '.text-secondary', text: /Issuing for #{Regexp.escape(target.display_name)}/

    request_credential(user_id: target.id)

    assert_response :success
    assert_includes response.body, SECRET
    credential = target.credentials.last
    assert_equal me, credential.issued_by
    assert_equal target, credential.user
    assert_equal 0, me.credentials.count
  end

  test 'an administrator can issue from an administrator-only provider for a member' do
    admin = sign_in_as_admin
    provider = create_credential_provider(self_service: false)
    target = create_member

    request_credential(provider: provider, user_id: target.id)

    assert_response :success
    assert_equal admin, target.credentials.last.issued_by
  end

  test 'issuing for a member who is not eligible is refused with the reason' do
    sign_in_as_admin
    target = create_member
    target.ban!

    request_credential(user_id: target.id)

    assert_redirected_to credentials_path
    assert_match(/active members/, flash[:alert])
  end

  test 'an unknown member email goes back to the admin list' do
    sign_in_as_admin

    get new_credential_path(provider_id: @provider.id, member_email: 'nobody@example.com')

    assert_redirected_to issued_credentials_path
    assert_match(/No member found/, flash[:alert])
  end

  test 'a member asking for their own id is not treated as issuing for someone else' do
    me = sign_in_as_plain_member

    request_credential(user_id: me.id)

    assert_response :success
    assert_equal 1, me.credentials.count
  end
end
