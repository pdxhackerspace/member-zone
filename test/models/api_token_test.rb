require 'test_helper'

class ApiTokenTest < ActiveSupport::TestCase
  setup do
    @member = users(:two)
    @admin = users(:one)
    @admin.update_columns(is_admin: true)
  end

  test 'a new token gets a prefixed secret, a digest, a hint, and the maximum expiry' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')

    assert token.token.start_with?('mz_')
    assert_equal ApiToken.digest(token.token), token.token_digest
    assert_equal token.token.last(4), token.token_hint
    assert_in_delta 365.days.from_now, token.expires_at, 5.seconds
    assert_equal @member, token.contact_user
  end

  test "a member's own token is looked after by the member, whoever created it" do
    token = ApiToken.create!(user: @member, created_by: @admin, name: 'Laptop')

    assert_equal @member, token.contact_user
  end

  test 'a service account token may have nobody to look after it' do
    token = ApiToken.create!(user: create_service_account, created_by: @admin, name: 'Kiosk')

    assert_nil token.contact_user
  end

  test 'looked_after_by covers your own tokens and those you are the contact for' do
    own = ApiToken.create!(user: @member, created_by: @member, name: 'Mine')
    kiosk = ApiToken.create!(user: create_service_account, created_by: @admin, contact_user: @member, name: 'Kiosk')
    ApiToken.create!(user: create_service_account, created_by: @admin, contact_user: @admin, name: 'Other')

    assert_equal [own, kiosk].map(&:id).sort, ApiToken.looked_after_by(@member).ids.sort
  end

  test 'the plaintext is not available once reloaded' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')

    assert_nil ApiToken.find(token.id).token
  end

  test 'the maximum lifetime comes from the setting' do
    DefaultSetting.instance.update!(api_token_max_lifetime_days: 30)
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')

    assert_in_delta 30.days.from_now, token.expires_at, 5.seconds
  end

  test 'an expiry beyond the maximum lifetime is refused' do
    token = ApiToken.new(user: @member, created_by: @member, name: 'Laptop', expires_at: 400.days.from_now)

    assert_not token.valid?
    assert token.errors[:expires_at].any?
  end

  test 'a shorter expiry is allowed' do
    assert ApiToken.new(user: @member, created_by: @member, name: 'Laptop', expires_at: 1.week.from_now).valid?
  end

  test 'a name is required' do
    assert_not ApiToken.new(user: @member, created_by: @member).valid?
  end

  test 'scopes are normalized' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop',
                             scopes: [' parking.own_permits', '', 'parking.own_permits'])

    assert_equal ['parking.own_permits'], token.scopes
  end

  test 'an unknown scope is refused' do
    token = ApiToken.new(user: @member, created_by: @member, name: 'Laptop', scopes: ['made.up'])

    assert_not token.valid?
    assert_includes token.errors[:scopes], 'made.up is not a privilege'
  end

  test 'a topic-scoped privilege cannot be a scope' do
    token = ApiToken.new(user: @admin, created_by: @admin, name: 'Laptop', scopes: ['audit_logs.view'])

    assert_not token.valid?
    assert_includes token.errors[:scopes], 'audit_logs.view only applies within a training topic'
  end

  test 'a holder cannot be given a scope they do not hold' do
    token = ApiToken.new(user: @member, created_by: @member, name: 'Laptop', scopes: ['parking.manage_notices'])

    assert_not token.valid?
    assert token.errors[:scopes].first.include?('is not held by')
  end

  test 'a holder with the privilege through a role may be given the scope' do
    grant_privileges(@member, 'parking.manage_notices')

    assert ApiToken.new(user: @member, created_by: @member, name: 'Laptop', scopes: ['parking.manage_notices']).valid?
  end

  test 'nobody grants a scope they do not hold themselves' do
    kiosk = create_service_account
    grant_privileges(kiosk, 'parking.manage_notices')
    token = ApiToken.new(user: kiosk, created_by: @member, name: 'Kiosk', scopes: ['parking.manage_notices'])

    assert_not token.valid?
    assert_includes token.errors[:scopes], 'parking.manage_notices is not yours to grant'
  end

  test 'an administrator may grant a service account a scope it holds' do
    kiosk = create_service_account
    grant_privileges(kiosk, 'parking.manage_notices')

    assert ApiToken.new(user: kiosk, created_by: @admin, name: 'Kiosk', scopes: ['parking.manage_notices']).valid?
  end

  test 'every active member holds the membership scopes' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop', scopes: ['parking.own_permits'])

    assert token.allows?('parking.own_permits')
  end

  test 'service accounts never hold membership scopes' do
    kiosk = create_service_account
    token = ApiToken.new(user: kiosk, created_by: @admin, name: 'Kiosk', scopes: ['parking.own_permits'])

    assert_not token.valid?
  end

  test 'allows? needs both the scope and the privilege' do
    grant_privileges(@member, 'parking.manage_notices', 'api.users.search')
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop', scopes: ['api.users.search'])

    assert token.allows?('api.users.search')
    assert token.allows?(:'api.users.search')
    assert_not token.allows?('parking.manage_notices')
  end

  test 'a holder who loses the privilege loses it on the token at once' do
    topic = grant_privileges(@member, 'api.users.search')
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop', scopes: ['api.users.search'])
    Training.where(trainee: @member, training_topic: topic).destroy_all

    assert_not ApiToken.find(token.id).allows?('api.users.search')
  end

  test 'an administrator token is still limited to its scopes' do
    token = ApiToken.create!(user: @admin, created_by: @admin, name: 'Laptop', scopes: ['api.users.search'])

    assert token.allows?('api.users.search')
    assert_not token.allows?('parking.manage_notices')
  end

  test 'authenticate finds a usable token by its secret' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')

    assert_equal token, ApiToken.authenticate(token.token)
    assert_nil ApiToken.authenticate('mz_nope')
    assert_nil ApiToken.authenticate(nil)
    assert_nil ApiToken.authenticate('')
  end

  test 'rejection reasons' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')
    assert_nil token.rejection_reason

    travel_to(token.expires_at + 1.second) { assert_equal :expired, token.rejection_reason }

    token.suspend!(by: @member)
    assert_equal :suspended, token.rejection_reason

    token.revoke!(by: @member)
    assert_equal :revoked, token.rejection_reason
  end

  test 'a token whose member is inactive is refused, and works again when they return' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')

    @member.update_columns(membership_state: 'inactive_member')
    assert_equal :holder_inactive, ApiToken.find(token.id).rejection_reason
    assert_nil ApiToken.authenticate(token.token)

    @member.update_columns(membership_state: 'current_member')
    assert_equal token, ApiToken.authenticate(token.token)
  end

  test 'a token whose service account is deactivated is refused' do
    kiosk = create_service_account
    token = ApiToken.create!(user: kiosk, created_by: @admin, name: 'Kiosk')
    kiosk.update_columns(active: false)

    assert_equal :holder_inactive, ApiToken.find(token.id).rejection_reason
  end

  test 'state reports what someone would have to undo' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')
    assert_equal 'active', token.state

    token.update_columns(expires_at: 1.minute.ago)
    assert_equal 'expired', token.state

    token.suspend!(by: @member)
    assert_equal 'suspended', token.state

    token.revoke!(by: @member)
    assert_equal 'revoked', token.state
  end

  test 'extending an expired token renews it with the same secret' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')
    secret = token.token
    token.update_columns(expires_at: 3.days.ago)
    assert_nil ApiToken.authenticate(secret)

    token.extend!(by: @member)

    assert_in_delta 365.days.from_now, token.expires_at, 5.seconds
    assert_not_nil token.last_extended_at
    assert_equal token, ApiToken.authenticate(secret)
    assert Journal.exists?(action: 'api_token_extended', user: @member)
  end

  test 'extensions do not stack' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')
    token.extend!(by: @member)
    token.extend!(by: @member)

    assert_in_delta 365.days.from_now, token.expires_at, 5.seconds
  end

  test 'suspend and resume' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')
    token.suspend!(by: @admin, reason: 'Investigating')

    assert_equal @admin, token.suspended_by
    assert_equal 'Investigating', token.suspended_reason
    assert_nil ApiToken.authenticate(token.token)

    token.resume!(by: @admin)
    assert_nil token.suspended_at
    assert_equal token, ApiToken.authenticate(token.token)
  end

  test 'revoking is permanent' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')
    token.revoke!(by: @admin, reason: 'Leaked')

    assert_equal @admin, token.revoked_by
    assert_raises(ActiveRecord::RecordInvalid) { token.extend!(by: @admin) }
    assert_raises(ActiveRecord::RecordInvalid) { token.resume!(by: @admin) }
    assert_raises(ActiveRecord::RecordInvalid) { token.suspend!(by: @admin) }
    assert_nil ApiToken.authenticate(token.token)
  end

  test 'revoking twice keeps the first record' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')
    token.revoke!(by: @admin, reason: 'Leaked')
    token.revoke!(by: @member, reason: 'Again')

    assert_equal @admin, token.reload.revoked_by
  end

  test 'lifecycle changes are journaled on the holder' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')
    token.revoke!(by: @admin)
    entry = Journal.find_by!(action: 'api_token_revoked', user: @member)

    assert_equal @admin, entry.actor_user
    assert_equal 'Laptop', entry.changes_json.dig('api_token', 'name')
    assert entry.highlight
  end

  test 'record_use! writes at most once a minute' do
    token = ApiToken.create!(user: @member, created_by: @member, name: 'Laptop')
    token.record_use!(ip: '10.0.0.1')
    first = token.reload.last_used_at

    token.record_use!(ip: '10.0.0.2')
    assert_equal first, token.reload.last_used_at
    assert_equal '10.0.0.1', token.last_used_ip

    travel 2.minutes do
      token.record_use!(ip: '10.0.0.3')
      assert_equal '10.0.0.3', token.reload.last_used_ip
    end
  end

  test 'scopes for usable, expired, suspended, and revoked tokens' do
    usable = ApiToken.create!(user: @member, created_by: @member, name: 'A')
    expired = ApiToken.create!(user: @member, created_by: @member, name: 'B')
    expired.update_columns(expires_at: 1.day.ago)
    suspended = ApiToken.create!(user: @member, created_by: @member, name: 'C')
    suspended.suspend!(by: @member)
    revoked = ApiToken.create!(user: @member, created_by: @member, name: 'D')
    revoked.revoke!(by: @member)

    assert_equal [usable], ApiToken.usable.to_a
    assert_equal [expired], ApiToken.expired.to_a
    assert_equal [suspended], ApiToken.suspended.to_a
    assert_equal [revoked], ApiToken.revoked.to_a
  end

  test 'personal and service tokens' do
    kiosk = create_service_account
    personal = ApiToken.create!(user: @member, created_by: @member, name: 'A')
    service = ApiToken.create!(user: kiosk, created_by: @admin, name: 'B')

    assert personal.personal?
    assert service.service?
    assert_equal [personal], ApiToken.personal.to_a
    assert_equal [service], ApiToken.service.to_a
  end

  test 'deleting the creator keeps a service account token' do
    creator = users(:three)
    creator.update_columns(is_admin: true)
    kiosk = create_service_account
    token = ApiToken.create!(user: kiosk, created_by: creator, name: 'Kiosk')
    creator.destroy!

    token.reload
    assert_nil token.created_by
    assert_nil token.contact_user
  end

  test 'deleting the holder deletes their tokens' do
    kiosk = create_service_account
    token = ApiToken.create!(user: kiosk, created_by: @admin, name: 'Kiosk')
    kiosk.destroy!

    assert_not ApiToken.exists?(token.id)
  end
end
