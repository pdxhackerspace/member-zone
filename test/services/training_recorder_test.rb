require 'test_helper'

class TrainingRecorderTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

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

  test 'admin attributing training messages that trainer and the other active trainers' do
    admin = admin_actor
    named = users(:one)
    other = users(:two)
    quiet = users(:no_email)
    inactive_trainer = inactive_member(:private_profile_user)
    trainee = inactive_member(:three)
    grant_topic_training(named, other, quiet, inactive_trainer)

    assert_difference 'Message.count', 3 do
      assert_enqueued_emails 2 do
        record_attributed(actor: admin, trainee: trainee, trainer: named)
      end
    end

    assert_equal admin, Message.find_by!(recipient: named).sender
    assert_includes Message.find_by!(recipient: named).body, 'named you as the trainer'
    assert_includes Message.find_by!(recipient: named).body, @trained_at.to_date.to_fs(:long)
    assert_includes Message.find_by!(recipient: other).body, "by #{named.display_name}"
    assert Message.exists?(recipient: quiet, sender: admin)
    assert_nil Message.find_by(recipient: admin)
    assert_nil Message.find_by(recipient: trainee)
    assert_nil Message.find_by(recipient: inactive_trainer)
  end

  test 'an inactive trainer named on the record is still told' do
    named = inactive_member(:one)
    grant_topic_training(users(:two))

    record_attributed(actor: admin_actor, trainee: @trainee, trainer: named)

    assert_includes Message.find_by!(recipient: named).body, 'named you as the trainer'
    assert_includes Message.find_by!(recipient: users(:two)).body, "by #{named.display_name}"
  end

  test 'admin naming an outside trainer still messages them and the topic trainers' do
    admin = admin_actor
    named = users(:one)
    topic_trainer = users(:two)
    TrainerCapability.create!(user: named, training_topic: training_topics(:woodworking))
    TrainerCapability.create!(user: topic_trainer, training_topic: @topic)

    record_attributed(actor: admin, trainee: @trainee, trainer: named)

    assert Message.exists?(recipient: named, sender: admin)
    assert_includes Message.find_by!(recipient: topic_trainer).body, "by #{named.display_name}"
  end

  test 'recording yourself as the trainer does not message the topic trainers' do
    admin = admin_actor
    TrainerCapability.create!(user: users(:two), training_topic: @topic)

    assert_no_difference 'Message.count' do
      record_attributed(actor: admin, trainee: @trainee, trainer: admin)
    end
  end

  test 'a trainer recording a class does not message other trainers' do
    grant_topic_training(@trainer, users(:two))

    assert_no_difference 'Message.count' do
      record_attributed(actor: @trainer, trainee: @trainee, trainer: users(:two))
    end
  end

  test 'skipping an already trained member does not message trainers' do
    admin = admin_actor
    named = users(:one)
    TrainerCapability.create!(user: named, training_topic: @topic)
    Training.create!(trainee: @trainee, trainer: named, training_topic: @topic, trained_at: 1.week.ago)

    assert_no_difference 'Message.count' do
      record_attributed(actor: admin, trainee: @trainee, trainer: named)
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
    inactive_member(:two).tap { |user| assert_not user.active? }
  end

  def inactive_member(fixture)
    users(fixture).tap { |user| user.update!(membership_state: 'inactive_member') }.reload
  end

  def admin_actor
    users(:public_profile_user).tap { |user| user.update_columns(is_admin: true) }
  end

  def grant_topic_training(*users)
    users.each { |user| TrainerCapability.create!(user: user, training_topic: @topic) }
  end

  def record_attributed(actor:, trainee:, trainer:)
    TrainingRecorder.new(
      current_user: actor, training_topic: @topic, trainee_ids: [trainee.id.to_s],
      trainer: trainer, trained_at: @trained_at
    ).call
  end

  def training_completed_mail_count(user)
    QueuedMail.where(recipient: user, mailer_action: 'training_completed').count
  end
end
