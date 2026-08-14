require 'test_helper'

module Reminders
  class OrientationEligibilityTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      @topic = training_topics(:building_access)
      MembershipSetting.instance.update!(
        orientation_reminder_repeat_days: 14,
        new_member_expiry_days: 90,
        building_access_training_topic: @topic
      )
    end

    test 'due includes an approved member with no orientation who has never been reminded' do
      user = awaiting_user(email: 'never-oriented@example.com')

      assert_includes OrientationEligibility.due(now: @now), user
      assert OrientationEligibility.due?(user, now: @now)
    end

    test 'due excludes a member who has already had building access training' do
      user = awaiting_user(email: 'already-trained@example.com')
      Training.create!(trainee: user, training_topic: @topic, trained_at: @now - 1.day)

      assert_not_includes OrientationEligibility.due(now: @now), user.reload
      assert_not OrientationEligibility.due?(user, now: @now)
    end

    test 'recording the orientation takes the member off the list' do
      user = awaiting_user(email: 'orientation-recorded@example.com')
      assert_includes OrientationEligibility.due(now: @now), user

      Training.create!(trainee: user, training_topic: @topic, trained_at: @now)

      assert_equal 'provisional_member', user.reload.membership_state
      assert_not_includes OrientationEligibility.due(now: @now), user
    end

    test 'due excludes a member whose new-member window has already run out' do
      user = awaiting_user(email: 'window-expired@example.com')
      user.update_columns(membership_state_entered_at: @now - 91.days)

      assert_not OrientationEligibility.due?(user.reload, now: @now)
    end

    test 'due excludes a member approved more recently than the interval' do
      user = awaiting_user(email: 'just-approved@example.com', approved_ago: 3.days)

      assert_not_includes OrientationEligibility.due(now: @now), user
      assert_not OrientationEligibility.due?(user, now: @now)
    end

    test 'due excludes members reminded inside the interval' do
      user = awaiting_user(email: 'recently-reminded@example.com')
      user.update_columns(orientation_reminder_sent_at: @now - 3.days)

      assert_not_includes OrientationEligibility.due(now: @now), user.reload
      assert_not OrientationEligibility.due?(user, now: @now)
    end

    test 'due includes members reminded outside the interval' do
      user = awaiting_user(email: 'reminded-long-ago@example.com')
      user.update_columns(orientation_reminder_sent_at: @now - 15.days)

      assert_includes OrientationEligibility.due(now: @now), user.reload
      assert OrientationEligibility.due?(user, now: @now)
    end

    test 'due excludes members with reminder mail still awaiting review' do
      user = awaiting_user(email: 'awaiting-review@example.com')
      queue_reminder_mail(user, status: 'pending')

      assert_not_includes OrientationEligibility.due(now: @now), user
      assert_not OrientationEligibility.due?(user, now: @now)
    end

    test 'due includes members whose reminder mail was rejected' do
      user = awaiting_user(email: 'rejected-reminder@example.com')
      queue_reminder_mail(user, status: 'rejected')

      assert_includes OrientationEligibility.due(now: @now), user
      assert OrientationEligibility.due?(user, now: @now)
    end

    test 'due excludes members with no email to write to' do
      user = awaiting_user(email: 'no-email@example.com')
      user.update_columns(email: nil, email_lookup_digest: nil)

      assert_not_includes OrientationEligibility.due(now: @now), user.reload
      assert_not OrientationEligibility.due?(user, now: @now)
    end

    test 'due excludes service accounts and legacy records' do
      service = awaiting_user(email: 'service-awaiting@example.com')
      service.update_columns(service_account: true)
      legacy = awaiting_user(email: 'legacy-awaiting@example.com')
      legacy.update_columns(legacy: true)

      assert_not_includes OrientationEligibility.due(now: @now), service.reload
      assert_not_includes OrientationEligibility.due(now: @now), legacy.reload
      assert_not OrientationEligibility.due?(service, now: @now)
      assert_not OrientationEligibility.due?(legacy, now: @now)
    end

    test 'total_awaiting counts everyone waiting regardless of reminder history' do
      awaiting_user(email: 'awaiting-a@example.com')
      reminded = awaiting_user(email: 'awaiting-b@example.com')
      reminded.update_columns(orientation_reminder_sent_at: @now)
      awaiting_user(email: 'awaiting-c@example.com', approved_ago: 1.day)

      assert_equal 3, OrientationEligibility.total_awaiting
      assert_equal 1, OrientationEligibility.count_due(now: @now)
    end

    # Without a topic there is nothing to have been trained on, so the state is all we have
    # to go on and filtering on training would silently empty the list.
    test 'with no building access topic configured every new member is still waiting' do
      MembershipSetting.instance.update!(building_access_training_topic: nil)
      @topic.update!(name: 'Unrelated Topic')
      user = awaiting_user(email: 'no-topic@example.com')
      Training.create!(trainee: user, training_topic: @topic, trained_at: @now - 1.day)

      assert_includes OrientationEligibility.due(now: @now), user.reload
    end

    private

    def awaiting_user(email:, approved_ago: 20.days)
      user = User.create!(
        email: email,
        full_name: 'Awaiting Orientation',
        service_account: false,
        membership_state: 'new_member',
        payment_type: 'unknown'
      )
      user.update_columns(membership_state_entered_at: @now - approved_ago)
      MembershipApplication.create!(
        user: user,
        email: email,
        status: 'approved',
        reviewed_at: @now - approved_ago,
        submitted_at: @now - approved_ago - 2.days
      )
      user.reload
    end

    def queue_reminder_mail(user, status:)
      QueuedMail.create!(
        to: user.email,
        subject: 'Book your orientation',
        body_html: '<p>Hi</p>',
        body_text: 'Hi',
        reason: 'Orientation not recorded',
        mailer_action: 'orientation_reminder',
        recipient: user,
        status: status,
        reviewed_by: status == 'rejected' ? users(:one) : nil,
        reviewed_at: status == 'rejected' ? @now - 1.day : nil
      )
    end
  end
end
