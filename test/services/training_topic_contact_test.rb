require 'test_helper'

class TrainingTopicContactTest < ActiveSupport::TestCase
  setup do
    @area = TrainingTopic.create!(name: 'Steward Woodshop', offered_to_members: true)
    @saw = TrainingTopic.create!(name: 'Table saw', parent: @area, offered_to_members: true)
    @steward = users(:one)
    @member = users(:three)
    @trained = users(:two)
    Training.create!(trainee: @steward, training_topic: @area, trained_at: Time.current)
    Training.create!(trainee: @trained, training_topic: @saw, trained_at: Time.current)
    Training.create!(trainee: users(:private_profile_user), training_topic: @saw, trained_at: Time.current)
  end

  test 'sends one message to each active trained member except the sender' do
    @saw.update!(trained_members_contactable: true)
    Training.create!(trainee: @member, training_topic: @saw, trained_at: Time.current)

    assert_difference 'Message.count', 2 do
      result = deliver(viewer: @member, sender: @member)

      assert_nil result.error
      assert_equal 2, result.sent_count
    end

    recipients = Message.where(sender: @member).pluck(:recipient_id)
    assert_equal [@trained.id, users(:private_profile_user).id].sort, recipients.sort
    assert_equal 'Shop question', Message.where(sender: @member).pick(:subject)
  end

  test 'refuses a member when the topic has not opted in' do
    assert_no_difference 'Message.count' do
      result = deliver(viewer: @member, sender: @member)

      assert_match(/cannot contact/, result.error)
      assert_equal 0, result.sent_count
    end
  end

  test 'a member trained in the parent can send without the setting' do
    assert_difference 'Message.count', 2 do
      result = deliver(viewer: @steward, sender: @steward)

      assert_nil result.error
    end
  end

  test 'refuses a blank or oversized message' do
    @saw.update!(trained_members_contactable: true)

    blank = deliver(viewer: @member, sender: @member, subject: '  ', body: '')
    assert_match(/required/, blank.error)

    huge = deliver(viewer: @member, sender: @member, body: 'a' * (TrainingTopicContact::MAX_BODY + 1))
    assert_match(/too long/, huge.error)
  end

  test 'records the real sender when the viewer and the sender differ' do
    @saw.update!(trained_members_contactable: true)

    assert_difference 'Message.count', 2 do
      deliver(viewer: @member, sender: @steward)
    end

    assert_equal [@steward.id], Message.order(:id).last(2).map(&:sender_id).uniq
  end

  private

  def deliver(viewer:, sender:, subject: 'Shop question', body: 'When is the saw free?')
    TrainingTopicContact.new(topic: @saw, viewer: viewer, sender: sender, subject: subject, body: body).deliver
  end
end
