require 'test_helper'

class UserTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test 'ordered_by_display_name sorts by name then email' do
    ordered = User.ordered_by_display_name.map(&:display_name)

    # Verify the list is sorted case-insensitively
    assert_equal(ordered, ordered.sort_by(&:downcase))

    # Verify all fixture users are included
    assert_includes ordered, 'Example User One'
    assert_includes ordered, 'Example User Two'
    assert_includes ordered, 'No Email User'
    assert_includes ordered, 'beta@example.com'
  end

  test 'allows users without email' do
    user = User.new(authentik_id: 'no-email', full_name: 'No Email')

    assert_predicate user, :valid?
  end

  test 'display_name falls back to authentik id' do
    user = User.new(authentik_id: 'fallback-id')

    assert_equal 'fallback-id', user.display_name
  end

  test 'with_attribute scope filters users by authentik attributes' do
    results = User.with_attribute(:department, 'Engineering')
    assert_equal ['user1@example.com'], results.pluck(:email)
  end

  test 'pause_key_access! sets the flag and timestamp' do
    user = users(:one)
    assert_not user.key_access_paused?

    freeze_time do
      assert user.pause_key_access!
      assert user.reload.key_access_paused?
      assert_equal Time.current, user.key_access_paused_at
    end
  end

  test 'pause_key_access! is a no-op when already paused' do
    user = users(:one)
    user.pause_key_access!
    original_time = user.key_access_paused_at

    travel 1.hour do
      assert_not user.pause_key_access!
      assert_equal original_time.to_i, user.reload.key_access_paused_at.to_i
    end
  end

  test 'resume_key_access! clears the flag and timestamp' do
    user = users(:one)
    user.pause_key_access!

    assert user.resume_key_access!
    user.reload
    assert_not user.key_access_paused?
    assert_nil user.key_access_paused_at
  end

  test 'resume_key_access! is a no-op when not paused' do
    user = users(:one)
    assert_not user.resume_key_access!
  end

  test 'key_access_paused and key_access_active scopes' do
    paused = users(:one)
    active = users(:two)
    paused.pause_key_access!
    active.resume_key_access!

    assert_includes User.key_access_paused, paused
    assert_not_includes User.key_access_paused, active
    assert_includes User.key_access_active, active
    assert_not_includes User.key_access_active, paused
  end

  test 'pausing key access does not mark the user dirty for authentik sync' do
    # cash_payer is paying + current, so its computed active status stays stable across saves
    user = users(:cash_payer)
    user.update!(authentik_dirty: false)
    assert_not user.reload.authentik_dirty?

    user.pause_key_access!

    assert_not user.reload.authentik_dirty?
  end

  test 'by_name_or_alias matches single-word full_name exactly' do
    user = User.create!(
      authentik_id: 'single-word-test',
      email: 'singleword@example.com',
      full_name: 'Madonna',
      active: true
    )

    assert_equal user, User.by_name_or_alias('Madonna').first
    assert_equal user, User.by_name_or_alias('madonna').first
  end

  test 'by_name_or_alias matches single-word alias exactly' do
    user = users(:one)
    user.update_columns(aliases: ['Cher'], full_name: 'Example User One')

    assert_equal user, User.by_name_or_alias('Cher').first
  end

  test 'by_name_or_alias does not match first word of multi-word full_name' do
    user = users(:one)
    assert_equal 'Example User One', user.full_name

    assert_nil User.by_name_or_alias('Example').first
    assert_nil User.by_name_or_alias('One').first
  end

  test 'by_name_or_alias still matches multi-word full_name exactly' do
    user = users(:one)
    assert_equal user, User.by_name_or_alias('Example User One').first
  end

  test 'approving an application requires the applications.approve privilege' do
    member = User.create!(
      authentik_id: 'finalize-test-member',
      email: 'finalize-test-member@example.com',
      is_admin: false,
      active: true
    )
    assert_not member.can?(:'applications.approve')

    grant_privileges(member, 'applications.approve')
    assert member.can?(:'applications.approve')
  end

  test 'admins may approve without holding the privilege' do
    admin = User.create!(
      authentik_id: 'finalize-test-admin',
      email: 'finalize-test-admin@example.com',
      is_admin: true,
      active: true
    )

    assert admin.can?(:'applications.approve')
  end

  # can? cannot answer "was this authority given to you?" — is_admin? makes it true for
  # everything. privilege_conferred? is what callers ask when the difference matters.
  test 'privilege_conferred? ignores the admin bypass' do
    admin = User.create!(
      authentik_id: 'conferred-test-admin',
      email: 'conferred-test-admin@example.com',
      is_admin: true,
      active: true
    )

    assert admin.can?(:'applications.approve')
    assert_not admin.privilege_conferred?(:'applications.approve')

    grant_privileges(admin, 'applications.approve')

    assert admin.privilege_conferred?(:'applications.approve')
  end

  test 'privilege_conferred? matches can? for a member who holds the role' do
    member = User.create!(
      authentik_id: 'conferred-test-member',
      email: 'conferred-test-member@example.com',
      active: true
    )

    assert_not member.privilege_conferred?(:'applications.approve')

    grant_privileges(member, 'applications.approve')

    assert member.privilege_conferred?(:'applications.approve')
    assert_not member.privilege_conferred?(:'applications.reject')
  end

  # Each verb is its own privilege: reviewing an application does not decide it, and deciding
  # it one way does not carry the others.
  test 'reviewing training does not confer the power to approve, reject, or park' do
    member = User.create!(
      authentik_id: 'finalize-test-reviewer',
      email: 'finalize-test-reviewer@example.com',
      active: true
    )
    grant_privileges(member, 'applications.review', 'applications.view_pii')

    assert member.can?(:'applications.review')
    assert_not member.can?(:'applications.approve')
    assert_not member.can?(:'applications.reject')
    assert_not member.can?(:'applications.park_review')
  end

  test 'rejecting does not confer approving' do
    member = User.create!(
      authentik_id: 'finalize-test-rejecter',
      email: 'finalize-test-rejecter@example.com',
      active: true
    )
    grant_privileges(member, 'applications.reject')

    assert member.can?(:'applications.reject')
    assert_not member.can?(:'applications.approve')
    assert_not member.can?(:'applications.park_review')
  end

  test 'changing mailing address clears coordinates and queues geocoding' do
    user = users(:one)
    user.update_columns(
      mailing_address: 'Old address',
      mailing_latitude: 45.5,
      mailing_longitude: -122.6,
      mailing_geocoded_at: 1.day.ago
    )

    assert_enqueued_with(job: MemberGeocodingJob, args: [user.id]) do
      user.update!(mailing_address: '7608 N Interstate Ave, Portland, OR')
    end

    user.reload
    assert_nil user.mailing_latitude
    assert_nil user.mailing_longitude
    assert_nil user.mailing_geocoded_at
  end

  test 'clearing mailing address clears coordinates without queuing geocoding' do
    user = users(:one)
    user.update_columns(
      mailing_address: 'Old address',
      mailing_latitude: 45.5,
      mailing_longitude: -122.6,
      mailing_geocoded_at: 1.day.ago
    )

    assert_no_enqueued_jobs only: MemberGeocodingJob do
      user.update!(mailing_address: nil)
    end

    user.reload
    assert_nil user.mailing_latitude
    assert_nil user.mailing_longitude
    assert_nil user.mailing_geocoded_at
  end
end
