require 'test_helper'

module Reminders
  class SlackSignupEligibilityTest < ActiveSupport::TestCase
    setup do
      MembershipSetting.instance.update!(
        slack_signup_reminder_initial_delay_days: 7,
        slack_signup_reminder_repeat_delay_days: 14,
        slack_signup_reminder_max_account_age_months: 6
      )
    end

    test 'due includes active members without slack past initial delay' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'needs-slack@example.com')

      travel_to now do
        assert_includes SlackSignupEligibility.due(now: now), user
      end
    end

    test 'due excludes members with linked slack users' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'has-slack@example.com')
      SlackUser.create!(
        slack_id: 'U-HAS-SLACK',
        username: 'linked',
        real_name: user.full_name,
        email: user.email,
        user_id: user.id,
        is_bot: false,
        deleted: false
      )

      travel_to now do
        assert_not_includes SlackSignupEligibility.due(now: now), user
      end
    end

    test 'due excludes members with legacy slack_id on user record' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'legacy-slack-id@example.com')
      user.update_columns(slack_id: 'U-LEGACY-SLACK')

      travel_to now do
        assert_not_includes SlackSignupEligibility.due(now: now), user
      end
    end

    test 'due excludes members with legacy slack_handle on user record' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'legacy-slack-handle@example.com')
      user.update_columns(slack_handle: 'legacymember')

      travel_to now do
        assert_not_includes SlackSignupEligibility.due(now: now), user
      end
    end

    test 'due excludes inactive members' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'inactive@example.com', active: false)

      travel_to now do
        assert_not_includes SlackSignupEligibility.due(now: now), user
      end
    end

    test 'due excludes members who joined before the account age limit' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'old-joiner@example.com')
      user.membership_applications.approved.first.update!(reviewed_at: now - 7.months)

      travel_to now do
        assert_not_includes SlackSignupEligibility.due(now: now), user
        assert_not SlackSignupEligibility.due?(user, now: now)
        assert_not_includes SlackSignupEligibility.active_without_slack_scope(now: now), user
      end
    end

    test 'active_without_slack_scope includes recent members without slack' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'recent-no-slack@example.com')

      travel_to now do
        assert_includes SlackSignupEligibility.active_without_slack_scope(now: now), user
      end
    end

    test 'due excludes banned members' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'banned-nag@example.com', membership_state: 'banned_member')

      travel_to now do
        assert_not_includes SlackSignupEligibility.due(now: now), user
        assert_not SlackSignupEligibility.due?(user, now: now)
      end
    end

    test 'due excludes deceased members' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'deceased-nag@example.com', membership_state: 'deceased_member')

      travel_to now do
        assert_not_includes SlackSignupEligibility.due(now: now), user
        assert_not SlackSignupEligibility.due?(user, now: now)
      end
    end

    test 'due excludes members nagged inside repeat window' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'recent-nag@example.com', slack_signup_reminder_sent_at: now - 3.days)

      travel_to now do
        assert_not_includes SlackSignupEligibility.due(now: now), user
      end
    end

    test 'due includes members nagged outside repeat window' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'old-nag@example.com', slack_signup_reminder_sent_at: now - 15.days)

      travel_to now do
        assert_includes SlackSignupEligibility.due(now: now), user
      end
    end

    test 'due excludes whitespace-only email addresses' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'whitespace-nag@example.com')
      user.update_columns(email: '   ')

      travel_to now do
        assert_not_includes SlackSignupEligibility.due(now: now), user
        assert_not SlackSignupEligibility.due?(user, now: now)
      end
    end

    test 'due excludes tab and newline-only email addresses' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'tab-nag@example.com')
      user.update_columns(email: "\t\n")

      travel_to now do
        assert_not_includes SlackSignupEligibility.due(now: now), user
        assert_not SlackSignupEligibility.due?(user, now: now)
      end
    end

    test 'due excludes members with pending slack signup nag mail' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'pending-nag-mail@example.com')
      QueuedMail.create!(
        to: user.email,
        subject: 'Join us on Slack',
        body_html: '<p>Hi</p>',
        body_text: 'Hi',
        reason: 'Slack signup reminder',
        mailer_action: 'slack_signup_reminder',
        recipient: user,
        status: 'pending'
      )

      travel_to now do
        assert_not_includes SlackSignupEligibility.due(now: now), user
        assert_not SlackSignupEligibility.due?(user, now: now)
      end
    end

    test 'due excludes members with legacy pending slack signup nag mail' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'legacy-pending-nag-mail@example.com')
      QueuedMail.create!(
        to: user.email,
        subject: 'Join us on Slack',
        body_html: '<p>Hi</p>',
        body_text: 'Hi',
        reason: 'Slack signup nag',
        mailer_action: 'slack_signup_nag',
        recipient: user,
        status: 'pending'
      )

      travel_to now do
        assert_not_includes SlackSignupEligibility.due(now: now), user
        assert_not SlackSignupEligibility.due?(user, now: now)
      end
    end

    test 'due includes members after slack signup nag mail was rejected' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = eligible_user(now: now, email: 'rejected-nag-mail@example.com')
      QueuedMail.create!(
        to: user.email,
        subject: 'Join us on Slack',
        body_html: '<p>Hi</p>',
        body_text: 'Hi',
        reason: 'Slack signup reminder',
        mailer_action: 'slack_signup_reminder',
        recipient: user,
        status: 'rejected',
        reviewed_by: users(:one),
        reviewed_at: now - 1.day
      )

      travel_to now do
        assert_includes SlackSignupEligibility.due(now: now), user
        assert SlackSignupEligibility.due?(user, now: now)
      end
    end

    test 'uses created_at when member has no approved application' do
      now = Time.zone.local(2026, 8, 5, 7, 0, 0)
      user = users(:two)
      user.update_columns(
        email: 'member-sync@example.com',
        active: true,
        aliases: [],
        slack_id: nil,
        slack_handle: nil,
        pronouns: nil,
        bio: nil,
        avatar: nil,
        dues_status: 'current',
        membership_status: 'paying',
        membership_state: 'current_member',
        created_at: now - 10.days,
        slack_signup_reminder_sent_at: nil
      )
      user.slack_user&.destroy

      travel_to now do
        assert_includes SlackSignupEligibility.due(now: now), user
      end
    end

    private

    def eligible_user(now:, email:, **attrs)
      nag_sent_at = attrs.delete(:slack_signup_reminder_sent_at)
      active_override = attrs.delete(:active)

      user = User.create!(
        {
          email: email,
          full_name: 'Slack Reminder Candidate',
          active: true,
          service_account: false,
          membership_state: 'current_member',
          payment_type: 'unknown'
        }.merge(attrs)
      )

      column_updates = {}
      column_updates[:active] = active_override unless active_override.nil?
      column_updates[:slack_signup_reminder_sent_at] = nag_sent_at unless nag_sent_at.nil?
      user.update_columns(column_updates) if column_updates.any?
      MembershipApplication.create!(
        user: user,
        email: email,
        status: 'approved',
        reviewed_at: now - 10.days,
        submitted_at: now - 12.days
      )
      user
    end
  end
end
