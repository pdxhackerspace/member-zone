require 'test_helper'

class CredentialTest < ActiveSupport::TestCase
  setup do
    @member = create_member
    @provider = create_credential_provider
  end

  test 'a new credential is pending and gets a request id' do
    credential = Credential.create!(credential_provider: @provider, user: @member)
    assert_equal 'pending', credential.status
    assert_match(Credential::UUID_FORMAT, credential.request_id)
  end

  test 'request ids are unique' do
    first = create_credential(provider: @provider, user: @member)
    assert_raises(ActiveRecord::RecordInvalid) do
      Credential.create!(credential_provider: @provider, user: @member, request_id: first.request_id)
    end
  end

  test 'status and revocation reason must be known' do
    credential = create_credential(provider: @provider, user: @member)
    credential.status = 'weird'
    assert_not credential.valid?
    credential.status = 'active'
    credential.revocation_reason = 'because'
    assert_not credential.valid?
    credential.revocation_reason = 'rotated'
    assert credential.valid?
  end

  test 'the label is limited' do
    assert_not Credential.new(credential_provider: @provider, user: @member, label: 'x' * 101).valid?
  end

  test 'status predicates' do
    Credential::STATUSES.each do |status|
      credential = Credential.new(status: status)
      assert credential.public_send(:"#{status}?")
      assert_equal %w[active paused revoke_failed].include?(status), credential.live?
    end
  end

  test 'revocable needs a live or expired credential with a handle' do
    assert create_credential(provider: @provider, user: @member).revocable?
    assert create_credential(provider: @provider, user: @member, status: 'expired').revocable?
    assert create_credential(provider: @provider, user: @member, status: 'revoke_failed').revocable?
    assert_not create_credential(provider: @provider, user: @member, status: 'revoked').revocable?
    assert_not create_credential(provider: @provider, user: @member, status: 'pending').revocable?
    assert_not create_credential(provider: @provider, user: @member, external_id: nil).revocable?
  end

  test 'rotatable needs an active credential at an available provider' do
    credential = create_credential(provider: @provider, user: @member)
    assert credential.rotatable?
    @provider.record_health!('unhealthy', nil)
    assert_not credential.reload.rotatable?
    assert_not create_credential(provider: @provider, user: @member, status: 'paused').rotatable?
  end

  test 'display_fields show non-secret fields whole and secret ones as first and last four' do
    credential = create_credential(provider: @provider, user: @member)
    fields = credential.display_fields.index_by { |field| field[:key] }
    assert_equal 'client-1', fields['client_id'][:display]
    assert_equal 'abcd…wxyz', fields['client_secret'][:display]
    assert_equal 'Client secret', fields['client_secret'][:label]
  end

  test 'a secret too short to hint shows only a mask' do
    credential = create_credential(provider: @provider, user: @member,
                                   field_hints: { 'client_id' => { 'value' => 'c' }, 'client_secret' => {} })
    secret = credential.display_fields.find { |field| field[:key] == 'client_secret' }
    assert_equal Credentials::FieldHints::MASK, secret[:display]
  end

  test 'expiring_soon is true only inside the warning window' do
    now = Time.current
    assert create_credential(provider: @provider, user: @member, expires_at: now + 3.days).expiring_soon?(now)
    assert_not create_credential(provider: @provider, user: @member, expires_at: now + 8.days).expiring_soon?(now)
    assert_not create_credential(provider: @provider, user: @member, expires_at: now - 1.day).expiring_soon?(now)
    assert_not create_credential(provider: @provider, user: @member, expires_at: nil).expiring_soon?(now)
  end

  test 'display name prefers the label, notice name names the provider too' do
    labelled = create_credential(provider: @provider, user: @member, label: 'laptop CLI')
    assert_equal 'laptop CLI', labelled.display_name
    assert_equal 'Fixture OAuth client - laptop CLI', labelled.notice_name

    plain = create_credential(provider: @provider, user: @member, label: nil)
    assert_equal 'Fixture OAuth client', plain.display_name
    assert_equal 'Fixture OAuth client', plain.notice_name
  end

  test 'status label and dot' do
    assert_equal 'Revocation failed', Credential.new(status: 'revoke_failed').status_label
    assert_equal 'Active', Credential.new(status: 'active').status_label
    assert_equal 'success', Credential.new(status: 'active').status_dot_class
    assert_equal 'danger', Credential.new(status: 'revoke_failed').status_dot_class
    assert_equal 'muted', Credential.new(status: 'revoked').status_dot_class
  end

  test 'scopes' do
    active = create_credential(provider: @provider, user: @member)
    paused = create_credential(provider: @provider, user: @member, status: 'paused')
    failed = create_credential(provider: @provider, user: @member, status: 'revoke_failed')
    revoked = create_credential(provider: @provider, user: @member, status: 'revoked')
    old_pending = create_credential(provider: @provider, user: @member, status: 'pending')
    old_pending.update_columns(created_at: 11.minutes.ago)
    fresh_pending = create_credential(provider: @provider, user: @member, status: 'pending')

    assert_equal [active, paused, failed].sort_by(&:id), Credential.live.where(user: @member).sort_by(&:id)
    assert_equal [failed], Credential.revoke_failed.where(user: @member).to_a
    assert_equal [old_pending], Credential.stale_pending.where(user: @member).to_a
    assert_not_includes Credential.stale_pending, fresh_pending
    assert_not_includes Credential.live, revoked
    assert_equal [active, paused, old_pending, fresh_pending].sort_by(&:id),
                 Credential.counting_toward_limit.where(user: @member).sort_by(&:id)
  end

  test 'expirable covers active and paused credentials with a date' do
    dated = create_credential(provider: @provider, user: @member, expires_at: 1.day.from_now)
    paused = create_credential(provider: @provider, user: @member, status: 'paused', expires_at: 1.day.from_now)
    create_credential(provider: @provider, user: @member)
    create_credential(provider: @provider, user: @member, status: 'revoked', expires_at: 1.day.from_now)
    assert_equal [dated, paused].sort_by(&:id), Credential.expirable.where(user: @member).sort_by(&:id)
  end

  test 'journal! records an entry for the member without secret material' do
    credential = create_credential(provider: @provider, user: @member, label: 'laptop', expires_at: 30.days.from_now)
    admin = users(:one)

    journal = credential.journal!('credential_issued', actor: admin, extra: { reason: 'because' })

    assert_equal @member, journal.user
    assert_equal admin, journal.actor_user
    assert_equal 'credential_issued', journal.action
    assert journal.highlight
    payload = journal.changes_json['credential']
    assert_equal credential.id, payload['id']
    assert_equal @provider.name, payload['provider']
    assert_equal 'laptop', payload['label']
    assert_equal 'because', payload['reason']
    assert_not_includes journal.changes_json.to_s, 'abcd'
  end

  test 'rotation links the new credential to the old one' do
    old = create_credential(provider: @provider, user: @member)
    replacement = create_credential(provider: @provider, user: @member, rotated_from: old)
    assert_equal replacement, old.reload.rotated_to
    assert_equal old, replacement.rotated_from
  end

  test 'destroying a user removes revoked credentials but is blocked by live ones' do
    gone = create_member
    create_credential(provider: @provider, user: gone, status: 'revoked')
    assert_difference 'Credential.count', -1 do
      assert gone.destroy
    end
  end
end
