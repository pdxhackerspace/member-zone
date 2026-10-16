require 'test_helper'

class TrainerAppointerTest < ActiveSupport::TestCase
  setup do
    @topic = training_topics(:laser_cutting)
    @actor = users(:one)
    @trained_at = 3.days.ago.change(usec: 0)
  end

  test 'appoints a trained member without recording another training' do
    trainee = users(:two)
    Training.create!(trainee: trainee, training_topic: @topic, trained_at: 1.week.ago)

    result = nil
    assert_no_difference 'Training.count' do
      result = appoint(trainee)
    end

    assert TrainerCapability.exists?(user: trainee, training_topic: @topic)
    assert_equal [1, 0, 0], [result.appointed_count, result.trained_count, result.skipped_count]
  end

  test 'records the missing training with the chosen trainer and date' do
    trainee = users(:no_email)

    result = appoint(trainee)

    training = Training.find_by!(trainee: trainee, training_topic: @topic)
    assert_equal @actor, training.trainer
    assert_equal @trained_at.to_i, training.trained_at.to_i
    assert_equal 1, result.trained_count
    assert Journal.exists?(user: trainee, action: 'training_added')
    assert Journal.exists?(user: trainee, action: 'trainer_capability_added')
  end

  test 'skips existing trainers, banned members, and unknown ids' do
    existing = users(:two)
    TrainerCapability.create!(user: existing, training_topic: @topic)
    banned = users(:three)
    banned.ban!

    result = nil
    assert_no_difference 'TrainerCapability.count' do
      result = TrainerAppointer.new(current_user: @actor, training_topic: @topic,
                                    trainee_ids: [existing.id, banned.id, 0],
                                    trainer: @actor, trained_at: @trained_at).call
    end

    assert_equal 0, result.appointed_count
    assert_equal 3, result.skipped_count
  end

  test 'emails the new trainer' do
    trainee = users(:two)

    assert_difference -> { QueuedMail.where(mailer_action: 'trainer_capability_granted').count }, 1 do
      appoint(trainee)
    end
  end

  private

  def appoint(trainee)
    TrainerAppointer.new(current_user: @actor, training_topic: @topic, trainee_ids: [trainee.id],
                         trainer: @actor, trained_at: @trained_at).call
  end
end
