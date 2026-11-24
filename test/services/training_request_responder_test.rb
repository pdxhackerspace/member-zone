require 'test_helper'

class TrainingRequestResponderTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @topic = training_topics(:laser_cutting)
    @request = training_requests(:pending_laser_request)
    @sender = users(:one)
    @other = users(:two)
    TrainerCapability.find_or_create_by!(user: @sender, training_topic: @topic)
    TrainerCapability.find_or_create_by!(user: @other, training_topic: @topic)
  end

  test 'sends the response to the member and a copy to each other active trainer' do
    TrainerCapability.find_or_create_by!(user: users(:no_email), training_topic: @topic)
    TrainerCapability.find_or_create_by!(user: @request.user, training_topic: @topic)

    assert_difference 'Message.count', 3 do
      assert_enqueued_emails 2 do
        result = respond(notify_other_trainers: true)

        assert result.success
        assert_equal 'Response sent to member and the other trainers.', result.notice
      end
    end

    member_message = Message.find_by!(recipient: @request.user)
    assert_equal 'See you Thursday.', member_message.body
    assert_equal 1, Message.where(recipient: @request.user).count

    copy = Message.find_by!(recipient: @other)
    assert_includes copy.body, 'See you Thursday.'
    assert_includes copy.body, @request.user.display_name

    quiet_copy = Message.find_by!(recipient: users(:no_email))
    assert_equal @sender, quiet_copy.sender
    assert_nil Message.find_by(recipient: @sender)
    @request.reload
    assert @request.pending?
    assert @request.replied?
    assert_equal @sender, @request.responded_by
  end

  test 'leaves other trainers out when the box is unchecked' do
    assert_difference 'Message.count', 1 do
      assert_enqueued_emails 1 do
        result = respond(notify_other_trainers: false)

        assert_equal 'Response sent to member.', result.notice
      end
    end

    assert_nil Message.find_by(recipient: @other)
  end

  test 'other trainers are the active trainers besides the sender and the member' do
    users(:three).update!(membership_state: 'inactive_member')
    TrainerCapability.find_or_create_by!(user: users(:three), training_topic: @topic)
    TrainerCapability.find_or_create_by!(user: @request.user, training_topic: @topic)

    trainers = TrainingRequestResponder.other_trainers(@request, sender: @sender)

    assert_equal [@other], trainers.to_a
  end

  private

  def respond(notify_other_trainers:)
    TrainingRequestResponder.new(
      request: @request,
      sender: @sender,
      body: 'See you Thursday.',
      notify_other_trainers: notify_other_trainers
    ).call
  end
end
