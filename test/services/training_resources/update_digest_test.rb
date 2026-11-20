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

    test 'the reminders summary counts waiting changes and who would be mailed today' do
      TrainingTopicLink.create!(training_topic: @topic, title: 'Guide', url: 'https://example.com/guide')
      summary = TrainingResources::UpdateDigest.summary

      assert_equal 1, summary.pending_count
      assert_equal 2, summary.due_recipient_count
      assert_match '1 change waiting across 1 topic', summary.context
    end
  end
end
