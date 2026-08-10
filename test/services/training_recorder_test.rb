require 'test_helper'

class TrainingRecorderTest < ActiveSupport::TestCase
  setup do
    @topic = training_topics(:laser_cutting)
    @trainer = users(:one)
    @trainee = users(:no_email)
    @trained_at = 3.days.ago.change(usec: 0)
  end

  test 'records a training event with trainer topic and date' do
    assert_difference 'Training.count', 1 do
      result = TrainingRecorder.new(
        current_user: @trainer,
        training_topic: @topic,
        trainee_ids: [@trainee.id.to_s],
        trainer: @trainer,
        trained_at: @trained_at
      ).call

      assert_equal 1, result.recorded_count
      assert_equal 0, result.skipped_count
    end

    training = Training.find_by!(trainee: @trainee, training_topic: @topic)
    assert_equal @trainer, training.trainer
    assert_equal @trained_at.to_i, training.trained_at.to_i
  end

  test 'creates a journal entry for recorded training' do
    assert_difference 'Journal.where(user: @trainee, action: "training_added").count', 1 do
      TrainingRecorder.new(
        current_user: @trainer,
        training_topic: @topic,
        trainee_ids: [@trainee.id.to_s],
        trainer: @trainer,
        trained_at: @trained_at
      ).call
    end

    journal = Journal.where(user: @trainee, action: 'training_added').order(:created_at).last
    assert_equal @topic.name, journal.changes_json.dig('training', 'topic')
    assert_equal @trainer.display_name, journal.changes_json.dig('training', 'trainer')
  end

  test 'clears pending training request when member is trained' do
    request = TrainingRequest.create!(
      user: @trainee,
      training_topic: @topic,
      share_contact_info: true,
      status: 'pending'
    )

    TrainingRecorder.new(
      current_user: @trainer,
      training_topic: @topic,
      trainee_ids: [@trainee.id.to_s],
      trainer: @trainer,
      trained_at: @trained_at
    ).call

    assert request.reload.responded?
    assert_equal @trainer, request.responded_by
  end

  test 'skips already trained banned and missing trainees' do
    already_trained = users(:two)
    banned = users(:three)
    banned.ban!
    Training.create!(
      trainee: already_trained,
      trainer: @trainer,
      training_topic: @topic,
      trained_at: 1.week.ago
    )

    assert_difference 'Training.count', 1 do
      result = TrainingRecorder.new(
        current_user: @trainer,
        training_topic: @topic,
        trainee_ids: [already_trained.id.to_s, banned.id.to_s, @trainee.id.to_s, '999999'],
        trainer: @trainer,
        trained_at: @trained_at
      ).call

      assert_equal 1, result.recorded_count
      assert_equal 3, result.skipped_count
    end

    assert_equal 1, Training.where(trainee: already_trained, training_topic: @topic).count
    assert_not Training.exists?(trainee: banned, training_topic: @topic)
    assert Training.exists?(trainee: @trainee, training_topic: @topic)
  end

  test 'records training for an inactive member' do
    inactive = inactive_user

    assert_difference 'Training.count', 1 do
      result = TrainingRecorder.new(
        current_user: @trainer,
        training_topic: @topic,
        trainee_ids: [inactive.id.to_s],
        trainer: @trainer,
        trained_at: @trained_at
      ).call

      assert_equal 1, result.recorded_count
      assert_equal 0, result.skipped_count
      assert_equal 1, result.inactive_count
    end

    assert Training.exists?(trainee: inactive, training_topic: @topic)
  end

  test 'does not notify an inactive member unless asked to' do
    inactive = inactive_user

    assert_no_difference 'training_completed_mail_count(inactive)' do
      TrainingRecorder.new(
        current_user: @trainer,
        training_topic: @topic,
        trainee_ids: [inactive.id.to_s],
        trainer: @trainer,
        trained_at: @trained_at
      ).call
    end
  end

  test 'notifies an inactive member when notify_inactive is set' do
    inactive = inactive_user

    assert_difference 'training_completed_mail_count(inactive)', 1 do
      TrainingRecorder.new(
        current_user: @trainer,
        training_topic: @topic,
        trainee_ids: [inactive.id.to_s],
        trainer: @trainer,
        trained_at: @trained_at,
        notify_inactive: true
      ).call
    end
  end

  test 'notifies an active member without being asked' do
    active = users(:two)

    assert_difference 'training_completed_mail_count(active)', 1 do
      TrainingRecorder.new(
        current_user: @trainer,
        training_topic: @topic,
        trainee_ids: [active.id.to_s],
        trainer: @trainer,
        trained_at: @trained_at
      ).call
    end
  end

  test 'inactive_count only counts members who were actually trained' do
    inactive = inactive_user
    Training.create!(trainee: inactive, trainer: @trainer, training_topic: @topic, trained_at: 1.week.ago)

    result = TrainingRecorder.new(
      current_user: @trainer,
      training_topic: @topic,
      trainee_ids: [inactive.id.to_s, @trainee.id.to_s],
      trainer: @trainer,
      trained_at: @trained_at
    ).call

    assert_equal 1, result.recorded_count
    assert_equal 1, result.skipped_count
    assert_equal 0, result.inactive_count
  end

  private

  def inactive_user
    user = users(:two)
    user.update!(membership_state: 'inactive_member')
    assert_not user.reload.active?
    user
  end

  def training_completed_mail_count(user)
    QueuedMail.where(recipient: user, mailer_action: 'training_completed').count
  end
end
