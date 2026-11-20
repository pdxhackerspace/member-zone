require 'test_helper'

module TrainingResources
  class UpdateDigestTest < ActiveSupport::TestCase
    setup do
      ReminderSetting.seed_defaults!
      EmailTemplate.seed_defaults!
      @setting = ReminderSetting.find_by!(key: 'training_resource_updates')
      @setting.update!(enabled: true, interval_days: 7)
      @topic = training_topics(:laser_cutting)
      @trained = users(:one)
      @trainer = users(:two)
      Training.create!(trainee: @trained, training_topic: @topic, trained_at: 2.days.ago)
      TrainerCapability.create!(user: @trainer, training_topic: @topic)
    end

    test 'one email goes to the trained member and the trainer, and a second batch waits out the interval' do
      TrainingTopicLink.create!(training_topic: @topic, title: '<script>', url: 'https://example.com/guide')

      TrainingResources::UpdateDigest.call

      mails = QueuedMail.where(mailer_action: 'training_resources_updated')
      assert_equal [@trained.id, @trainer.id].sort, mails.pluck(:recipient_id).sort
      body = mails.find_by!(recipient: @trained).body_html
      assert_includes body, 'Laser Cutting'
      assert_includes body, '&lt;script&gt;'
      assert_not_includes body, '<script>'
      assert TrainingResourceChange.pending.none?

      TrainingTopicLink.create!(training_topic: @topic, title: 'Second', url: 'https://example.com/second')
      TrainingResources::UpdateDigest.call
      assert_equal 2, mails.reload.count

      travel 8.days do
        TrainingResources::UpdateDigest.call
        assert_equal 4, QueuedMail.where(mailer_action: 'training_resources_updated').count
      end
    end

    test 'adding and then removing a link before the digest sends nothing' do
      link = TrainingTopicLink.create!(training_topic: @topic, title: 'Guide', url: 'https://example.com/guide')
      link.destroy!

      TrainingResources::UpdateDigest.call

      assert_empty QueuedMail.where(mailer_action: 'training_resources_updated')
      assert TrainingResourceChange.pending.none?
    end

    test 'a member trained after the change, an opted-out member, and an inactive member are left out' do
      late = users(:three)
      Training.create!(trainee: late, training_topic: @topic, trained_at: 1.hour.from_now)
      NotificationOptOut.opt_out!(@trained, category: 'training_resource_updates')
      @trainer.allow_any_membership_state_transition = true
      @trainer.update!(membership_state: 'inactive_member')
      TrainingTopicLink.create!(training_topic: @topic, title: 'Guide', url: 'https://example.com/guide')

      TrainingResources::UpdateDigest.call

      assert_empty QueuedMail.where(mailer_action: 'training_resources_updated')
      assert TrainingResourceChange.pending.none?
    end

    test 'send now ignores the interval' do
      TrainingTopicLink.create!(training_topic: @topic, title: 'Guide', url: 'https://example.com/guide')
      TrainingResources::UpdateDigest.call
      TrainingTopicLink.create!(training_topic: @topic, title: 'More', url: 'https://example.com/more')

      TrainingResources::SendDigest.call

      assert_equal 4, QueuedMail.where(mailer_action: 'training_resources_updated').count
    end

    test 'removing a link and adding it again still tells people it came back' do
      [3.hours.ago, 2.hours.ago, 1.hour.ago].zip(
        %w[link_added link_removed link_added],
        ['Guide', 'Guide', 'Came back']
      ).each do |at, kind, title|
        TrainingResourceChange.create!(
          training_topic: @topic, resource_type: 'TrainingTopicLink', resource_id: 9001,
          kind: kind, title: title, details: { 'url' => 'https://example.com/guide' }, occurred_at: at
        )
      end

      TrainingResources::UpdateDigest.call

      body = QueuedMail.find_by!(recipient: @trained, mailer_action: 'training_resources_updated').body_html
      assert_includes body, 'Came back'
      assert_not_includes body, 'Link removed'
    end

    test 'one failed recipient does not let the next day mail everyone else' do
      TrainingTopicLink.create!(training_topic: @topic, title: 'Guide', url: 'https://example.com/guide')
      fail_trainer_profile_url { TrainingResources::UpdateDigest.call }

      assert_equal [@trained.id], QueuedMail.where(mailer_action: 'training_resources_updated').pluck(:recipient_id)
      assert TrainingResourceChange.pending.any?

      TrainingTopicLink.create!(training_topic: @topic, title: 'More', url: 'https://example.com/more')
      TrainingResources::UpdateDigest.call
      assert_equal 1, QueuedMail.where(mailer_action: 'training_resources_updated').count

      travel 8.days do
        TrainingResources::UpdateDigest.call
      end

      mails = QueuedMail.where(mailer_action: 'training_resources_updated')
      assert_equal 3, mails.count
      assert_includes mails.find_by!(recipient: @trainer).body_html, 'Guide'
      assert_includes mails.where(recipient: @trained).order(:id).last.body_html, 'More'
    end

    test 'the reminders summary counts waiting changes and who would be mailed today' do
      TrainingTopicLink.create!(training_topic: @topic, title: 'Guide', url: 'https://example.com/guide')
      summary = TrainingResources::UpdateDigest.summary

      assert_equal 1, summary.pending_count
      assert_equal 2, summary.due_recipient_count
      assert_match '1 change waiting across 1 topic', summary.context
    end

    private

    def fail_trainer_profile_url
      real = nil
      real = MemberMailer.method(:profile_url_for)
      trainer = @trainer
      MemberMailer.define_singleton_method(:profile_url_for) do |user|
        raise 'smtp down' if user == trainer

        real.call(user)
      end
      yield
    ensure
      MemberMailer.define_singleton_method(:profile_url_for) { |user| real.call(user) } if real
    end
  end
end
