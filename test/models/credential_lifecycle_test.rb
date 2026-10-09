require 'test_helper'

class CredentialLifecycleTest < ActiveJob::TestCase
  setup do
    @member = create_member
    @provider = create_credential_provider
    @credential = create_credential(provider: @provider, user: @member)
  end

  test 'banning a member enqueues a sync' do
    assert_enqueued_with(job: Credentials::MemberSyncJob, args: [@member.id]) { @member.ban! }
  end

  test 'a member marked deceased enqueues a sync' do
    assert_enqueued_with(job: Credentials::MemberSyncJob, args: [@member.id]) { @member.mark_deceased! }
  end

  test 'a membership that ends enqueues a sync' do
    assert_enqueued_with(job: Credentials::MemberSyncJob, args: [@member.id]) do
      @member.transition_to!('inactive_member')
    end
  end

  test 'the membership expiring on a deadline enqueues a sync when it is materialized' do
    @member.update_columns(membership_state: 'cancelled_member', membership_state_entered_at: 1.year.ago)
    @member.reload

    assert_enqueued_with(job: Credentials::MemberSyncJob, args: [@member.id]) do
      @member.transition_to!('inactive_member')
    end
  end

  test 'pausing and resuming key access enqueue a sync' do
    assert_enqueued_with(job: Credentials::MemberSyncJob, args: [@member.id]) { @member.pause_key_access! }
    assert_enqueued_with(job: Credentials::MemberSyncJob, args: [@member.id]) { @member.resume_key_access! }
  end

  test 'reactivating a member enqueues a sync too, which resumes rather than restores' do
    @member.ban!
    clear_enqueued_jobs

    assert_enqueued_with(job: Credentials::MemberSyncJob, args: [@member.id]) { @member.transition_to!('current_member') }
  end

  test 'unrelated changes do not enqueue anything' do
    assert_no_enqueued_jobs(only: Credentials::MemberSyncJob) do
      @member.update!(full_name: 'Someone Else', bio: 'Hello')
    end
  end

  test 'a member with no live credentials does not enqueue anything' do
    @credential.update!(status: 'revoked')

    assert_no_enqueued_jobs(only: Credentials::MemberSyncJob) { @member.ban! }
  end

  test 'a member with only a failed revoke, which the reconciler owns, does not enqueue' do
    @credential.update!(status: 'revoke_failed')

    assert_no_enqueued_jobs(only: Credentials::MemberSyncJob) { @member.ban! }
  end

  test 'a paused credential is enough to enqueue' do
    @credential.update!(status: 'paused')

    assert_enqueued_with(job: Credentials::MemberSyncJob, args: [@member.id]) { @member.ban! }
  end

  test 'a credential still being issued is enough to enqueue' do
    @credential.update!(status: 'pending')

    assert_enqueued_with(job: Credentials::MemberSyncJob, args: [@member.id]) { @member.ban! }
  end

  test 'end to end, banning a member revokes their credentials through the real program' do
    perform_enqueued_jobs(only: Credentials::MemberSyncJob) { @member.ban! }

    assert_equal 'revoked', @credential.reload.status
    assert_equal 'member_inactive', @credential.revocation_reason
    assert_equal 1, QueuedMail.where(mailer_action: 'credentials_revoked', recipient: @member).count
  end

  test 'end to end, pausing and resuming key access pauses and resumes' do
    perform_enqueued_jobs(only: Credentials::MemberSyncJob) { @member.pause_key_access! }
    assert_equal 'paused', @credential.reload.status

    perform_enqueued_jobs(only: Credentials::MemberSyncJob) { @member.resume_key_access! }
    assert_equal 'active', @credential.reload.status
  end

  test 'a member with a live credential cannot be destroyed' do
    assert_no_difference 'User.count' do
      assert_not @member.destroy
    end
    assert_includes @member.errors.full_messages.to_sentence, 'Revoke'
    assert_equal 1, Credential.where(user: @member).count
  end

  test 'paused and revoke_failed credentials block destroying a member too' do
    @credential.update!(status: 'paused')
    assert_not @member.destroy
    @credential.update!(status: 'revoke_failed')
    assert_not @member.destroy
  end

  test 'a member whose credentials are all finished can be destroyed, taking the records with them' do
    @credential.update!(status: 'revoked')
    create_credential(provider: @provider, user: @member, status: 'expired')

    assert_difference 'User.count' => -1, 'Credential.count' => -2 do
      assert @member.destroy
    end
  end

  test 'destroying a member removes who-issued-it references without deleting the credential' do
    admin = create_member
    issued = create_credential(provider: @provider, user: @member, issued_by: admin, status: 'revoked')

    assert admin.destroy
    assert_nil issued.reload.issued_by_id
  end
end
