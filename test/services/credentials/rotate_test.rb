require 'test_helper'

module Credentials
  class RotateTest < ActiveSupport::TestCase
    SECRET = 'abcd-secret-value-wxyz'.freeze

    setup do
      @member = create_member
      @provider = create_credential_provider(max_per_member: 1)
      @old = create_credential(provider: @provider, user: @member, label: 'laptop CLI')
    end

    test 'issues a replacement first, then revokes the old credential' do
      result = Rotate.call(@old, by: @member, request_id: SecureRandom.uuid)

      assert_predicate result, :ok?
      assert_equal SECRET, result.fields['client_secret']
      replacement = result.credential.reload
      assert_equal 'active', replacement.status
      assert_equal @old, replacement.rotated_from
      assert_equal 'laptop CLI', replacement.label
      assert_equal @member, replacement.user
      assert_equal(%w[issue revoke], credential_calls.map { |line| line.split.first })

      @old.reload
      assert_equal 'revoked', @old.status
      assert_equal 'rotated', @old.revocation_reason
      assert_equal @member, @old.revoked_by
      assert_nil result.warning
    end

    test 'works at the per-member limit because the old credential is being replaced' do
      assert_match(/Limit of 1/, @provider.issue_denial_reason(@member))

      assert_predicate Rotate.call(@old, by: @member), :ok?
    end

    test 'the new secret is not stored' do
      Rotate.call(@old, by: @member)

      assert_secret_not_stored(SECRET)
    end

    test 'a credential that already has a replacement on the way is not rotated again' do
      create_credential(provider: @provider, user: @member, status: 'pending', rotated_from: @old,
                        external_id: nil)

      result = Rotate.call(@old, by: @member, request_id: SecureRandom.uuid)

      assert_not_predicate result, :ok?
      assert_equal 'This credential is already being replaced.', result.error
      assert_empty credential_calls
      assert_equal 'active', @old.reload.status
    end

    test 'two rotations of one credential submitted together leave one live replacement' do
      stale_copy = Credential.find(@old.id)
      first = Rotate.call(@old, by: @member, request_id: SecureRandom.uuid)
      assert_predicate first, :ok?

      # The second request loaded the credential before the first finished, so its copy still
      # reads active; the check under the member lock is what stops it.
      second = Rotate.call(stale_copy, by: @member, request_id: SecureRandom.uuid)

      assert_not_predicate second, :ok?
      assert_equal 1, @member.credentials.where(credential_provider: @provider).live.count
      assert_equal(1, credential_calls.count { |line| line.start_with?('issue') })
    end

    test 'a replacement that failed does not stop a later rotation' do
      create_credential(provider: @provider, user: @member, status: 'failed', rotated_from: @old, external_id: nil)

      assert_predicate Rotate.call(@old, by: @member, request_id: SecureRandom.uuid), :ok?
    end

    test 'the old credential is told why it was revoked' do
      Rotate.call(@old, by: @member)

      assert_equal 'rotated', credential_stdin('revoke')['reason']
      assert_equal @old.external_id, credential_stdin('revoke')['external_id']
    end

    test 'if the old credential cannot be revoked the new one is still returned with a warning' do
      provider = create_credential_provider(env: { FAIL_REVOKE: '1' })
      old = create_credential(provider: provider, user: @member)

      result = Rotate.call(old, by: @member)

      assert_predicate result, :ok?
      assert_match(/could not be revoked/, result.warning)
      assert_equal 'revoke_failed', old.reload.status
      assert_equal 'active', result.credential.reload.status
    end

    test 'if the new credential cannot be issued the old one is left alone' do
      provider = create_credential_provider(env: { FAIL_ISSUE: '1' })
      old = create_credential(provider: provider, user: @member)

      result = Rotate.call(old, by: @member)

      assert_not_predicate result, :ok?
      assert_equal 'active', old.reload.status
      assert_not_includes credential_calls.map { |line| line.split.first }, 'revoke'
    end

    test 'only an active credential at an available provider can be rotated' do
      paused = create_credential(provider: create_credential_provider, user: @member, status: 'paused')
      revoked = create_credential(provider: create_credential_provider, user: @member, status: 'revoked')

      [paused, revoked].each do |credential|
        result = Rotate.call(credential, by: @member)
        assert_not_predicate result, :ok?
        assert_equal 'This credential cannot be rotated.', result.error
      end
      @provider.record_health!('unhealthy', nil)
      assert_not_predicate Rotate.call(@old.reload, by: @member), :ok?
    end

    test 'a member who is no longer active cannot rotate and keeps the old credential' do
      @member.ban!

      result = Rotate.call(@old, by: @member)

      assert_not_predicate result, :ok?
      assert_equal 'active', @old.reload.status
    end

    test 'an administrator can rotate on the member behalf' do
      admin = users(:one)
      provider = create_credential_provider(self_service: false)
      old = create_credential(provider: provider, user: @member)

      result = Rotate.call(old, by: admin)

      assert_predicate result, :ok?
      assert_equal admin, result.credential.issued_by
      assert_equal admin, old.reload.revoked_by
    end

    test 'a repeated request id does not rotate twice' do
      request_id = SecureRandom.uuid
      assert_predicate Rotate.call(@old, by: @member, request_id: request_id), :ok?

      replay = Rotate.call(@old.reload, by: @member, request_id: request_id)

      assert_not_predicate replay, :ok?
    end
  end
end
