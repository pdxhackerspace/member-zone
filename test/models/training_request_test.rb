require 'test_helper'

class TrainingRequestTest < ActiveSupport::TestCase
  test 'cannot create duplicate pending request for same user and topic' do
    existing = training_requests(:pending_laser_request)

    duplicate = TrainingRequest.new(
      user: existing.user,
      training_topic: existing.training_topic,
      share_contact_info: true,
      status: 'pending'
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:training_topic_id], 'already has an active request for this member'
  end

  test 'allows new request for same user and topic when previous request was responded' do
    responded = training_requests(:responded_woodworking_request)
    request = TrainingRequest.new(
      user: responded.user,
      training_topic: responded.training_topic,
      share_contact_info: true,
      status: 'pending'
    )

    assert request.valid?
  end

  test 'dismiss! records the dismissal time and is idempotent' do
    request = training_requests(:responded_woodworking_request)
    assert_not request.dismissed?

    request.dismiss!
    request.reload

    assert request.dismissed?
    assert_not_nil request.dismissed_at

    original_time = request.dismissed_at
    request.dismiss!
    assert_equal original_time, request.reload.dismissed_at
  end

  test 'not_dismissed and dismissed scopes partition by dismissal' do
    dismissed = training_requests(:responded_woodworking_request)
    dismissed.dismiss!
    active = training_requests(:pending_laser_request)

    assert_includes TrainingRequest.not_dismissed, active
    assert_not_includes TrainingRequest.not_dismissed, dismissed
    assert_includes TrainingRequest.dismissed, dismissed
    assert_not_includes TrainingRequest.dismissed, active
  end

  test 'a reply keeps the request on every trainer dashboard for the topic' do
    request = training_requests(:pending_laser_request)
    topic = request.training_topic
    trainer = users(:one)
    other = users(:two)
    TrainerCapability.find_or_create_by!(user: trainer, training_topic: topic)
    TrainerCapability.find_or_create_by!(user: other, training_topic: topic)

    request.record_reply!(trainer)

    assert request.pending?
    assert request.replied?
    assert_equal trainer, request.responded_by
    assert_includes TrainingRequest.for_trainer_dashboard(trainer), request
    assert_includes TrainingRequest.for_trainer_dashboard(other), request
    assert_not_includes TrainingRequest.for_trainer_dashboard(users(:three)), request
    assert_not_includes TrainingRequest.awaiting_member_acknowledgement, request
  end

  test 'a reply does not change a request that is no longer open' do
    request = training_requests(:responded_woodworking_request)
    original_responder = request.responded_by

    request.record_reply!(users(:one))

    assert_equal 'responded', request.reload.status
    assert_equal original_responder, request.responded_by
  end

  test 'dismiss_for_trainers! removes the request for every trainer without completing it' do
    request = training_requests(:pending_laser_request)
    topic = request.training_topic
    trainer = users(:one)
    other = users(:two)
    TrainerCapability.find_or_create_by!(user: trainer, training_topic: topic)
    TrainerCapability.find_or_create_by!(user: other, training_topic: topic)
    request.record_reply!(trainer)

    request.dismiss_for_trainers!
    request.dismiss_for_trainers!

    assert request.closed?
    assert_not_includes TrainingRequest.for_trainer_dashboard(trainer), request
    assert_not_includes TrainingRequest.for_trainer_dashboard(other), request
    assert_not_includes TrainingRequest.awaiting_member_acknowledgement, request

    replacement = TrainingRequest.new(
      user: request.user,
      training_topic: topic,
      share_contact_info: true,
      status: 'pending'
    )
    assert replacement.valid?
  end

  test 'recording training takes a replied request off the trainer dashboard' do
    request = training_requests(:pending_laser_request)
    trainer = users(:one)
    TrainerCapability.find_or_create_by!(user: trainer, training_topic: request.training_topic)
    request.record_reply!(trainer)

    Training.create!(
      trainee: request.user,
      trainer: trainer,
      training_topic: request.training_topic,
      trained_at: Time.current
    )

    assert request.reload.responded?
    assert_not_includes TrainingRequest.for_trainer_dashboard(trainer), request
    assert_includes TrainingRequest.awaiting_member_acknowledgement, request
  end

  test 'awaiting_member_acknowledgement returns responded requests that are not dismissed' do
    responded = training_requests(:responded_woodworking_request)
    pending = training_requests(:pending_laser_request)

    assert_includes TrainingRequest.awaiting_member_acknowledgement, responded
    assert_not_includes TrainingRequest.awaiting_member_acknowledgement, pending

    responded.dismiss!
    assert_not_includes TrainingRequest.awaiting_member_acknowledgement, responded
  end
end
