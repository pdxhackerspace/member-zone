require 'test_helper'

class TrainingRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @topic = training_topics(:woodworking)
    TrainerCapability.find_or_create_by!(user: users(:one), training_topic: @topic)
    TrainerCapability.find_or_create_by!(user: users(:two), training_topic: @topic)
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'member can request training for offered topic' do
    sign_in_as_member
    member = User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")

    assert_difference 'TrainingRequest.count', 1 do
      assert_difference 'QueuedMail.count', 3 do
        post training_requests_path, params: {
          training_request: {
            training_topic_id: @topic.id,
            share_contact_info: '1'
          }
        }
      end
    end

    request = TrainingRequest.order(:created_at).last
    assert_equal 'pending', request.status
    assert_redirected_to user_path(member, tab: :profile)
  end

  test 'training request only emails trainers whose membership is active' do
    users(:two).update!(membership_state: 'inactive_member')

    sign_in_as_member

    assert_difference 'TrainingRequest.count', 1 do
      assert_difference 'QueuedMail.count', 2 do
        post training_requests_path, params: {
          training_request: {
            training_topic_id: @topic.id,
            share_contact_info: '1'
          }
        }
      end
    end

    recipient_ids = QueuedMail.order(:id).last(2).map(&:recipient_id)
    assert_not_includes recipient_ids, users(:two).id
    assert_includes recipient_ids, users(:one).id
  end

  test 'topic whose only trainer is inactive is not requestable' do
    users(:one).update!(membership_state: 'inactive_member')
    users(:two).update!(membership_state: 'inactive_member')

    assert_not TrainingTopic.available_for_member_requests.exists?(id: @topic.id)
  end

  test 'member can submit training request without sharing contact info' do
    sign_in_as_member
    member = User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")

    assert_difference 'TrainingRequest.count', 1 do
      post training_requests_path, params: {
        training_request: {
          training_topic_id: @topic.id,
          share_contact_info: '0'
        }
      }
    end

    request = TrainingRequest.order(:created_at).last
    assert_not request.share_contact_info
    assert_redirected_to user_path(member, tab: :profile)
  end

  test 'trainer notification uses withheld email when member did not share contact info' do
    sign_in_as_member
    member = User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")
    member.update!(slack_handle: 'trainee-slack')

    post training_requests_path, params: {
      training_request: {
        training_topic_id: @topic.id,
        share_contact_info: '0'
      }
    }

    trainer_mail = QueuedMail.where(recipient_id: users(:one).id).order(:id).last
    assert trainer_mail
    assert_equal 'withheld', trainer_mail.mailer_args['requester_email']
    assert_equal '', trainer_mail.mailer_args['requester_slack']
    assert_equal false, trainer_mail.mailer_args['share_contact_info']
  end

  test 'trainer notification includes slack handle when member shared contact info' do
    sign_in_as_member
    member = User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")
    member.update!(slack_handle: 'trainee-slack')

    post training_requests_path, params: {
      training_request: {
        training_topic_id: @topic.id,
        share_contact_info: '1'
      }
    }

    trainer_mail = QueuedMail.where(recipient_id: users(:one).id).order(:id).last
    assert trainer_mail
    assert_equal 'trainee-slack', trainer_mail.mailer_args['requester_slack']
    assert_equal member.email, trainer_mail.mailer_args['requester_email']
  end

  test 'member can open new training request page' do
    sign_in_as_member

    get new_training_request_path
    assert_response :success
    assert_match(/Request Training/i, response.body)
    assert_match 'name="training_request[training_topic_id]"', response.body
    assert_match 'name="training_request[share_contact_info]"', response.body
  end

  test 'trainer can open response form for request in their topic' do
    trainer = sign_in_as_trainer
    TrainerCapability.find_or_create_by!(user: trainer, training_topic: training_topics(:laser_cutting))

    get edit_training_request_path(training_requests(:pending_laser_request))
    assert_response :success
  end

  test 'member cannot open response form for request' do
    sign_in_as_member

    get edit_training_request_path(training_requests(:pending_laser_request))
    assert_redirected_to user_path(User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}"))
  end

  test 'trainer can respond to request in member zone' do
    trainer = sign_in_as_trainer
    TrainerCapability.find_or_create_by!(user: trainer, training_topic: training_topics(:laser_cutting))
    request = training_requests(:pending_laser_request)

    assert_difference 'Message.count', 1 do
      patch training_request_path(request), params: {
        training_request: {
          response_body: 'Happy to help. Please message me in #help to schedule.'
        }
      }
    end

    request.reload
    assert_equal 'responded', request.status
    assert_equal trainer, request.responded_by
    assert_not_nil request.responded_at
  end

  test 'trainer can mark a request as trained which records training and closes the request' do
    trainer = sign_in_as_trainer
    TrainerCapability.find_or_create_by!(user: trainer, training_topic: training_topics(:laser_cutting))
    request = training_requests(:pending_laser_request)

    assert_difference 'Training.count', 1 do
      post mark_trained_training_request_path(request)
    end

    request.reload
    assert_equal 'responded', request.status
    assert_equal trainer, request.responded_by

    training = Training.order(:created_at).last
    assert_equal request.user, training.trainee
    assert_equal trainer, training.trainer
    assert_equal request.training_topic, training.training_topic
  end

  test 'marking trained when member already trained closes the request without a duplicate record' do
    trainer = sign_in_as_trainer
    topic = training_topics(:laser_cutting)
    TrainerCapability.find_or_create_by!(user: trainer, training_topic: topic)
    member = training_requests(:pending_laser_request).user
    Training.create!(trainee: member, trainer: trainer, training_topic: topic, trained_at: Time.current)

    later_request = TrainingRequest.create!(
      user: member, training_topic: topic, share_contact_info: true, status: 'pending'
    )

    assert_no_difference 'Training.count' do
      post mark_trained_training_request_path(later_request)
    end

    assert_equal 'responded', later_request.reload.status
  end

  test 'admin can mark a request as trained' do
    sign_in_as_admin
    request = training_requests(:pending_laser_request)

    assert_difference 'Training.count', 1 do
      post mark_trained_training_request_path(request)
    end

    assert_equal 'responded', request.reload.status
  end

  test 'member cannot mark a request as trained' do
    sign_in_as_member
    request = training_requests(:pending_laser_request)

    assert_no_difference 'Training.count' do
      post mark_trained_training_request_path(request)
    end

    member = User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")
    assert_redirected_to user_path(member)
    assert_equal 'pending', request.reload.status
  end

  test 'member can dismiss their own completed training request' do
    sign_in_as_member
    member = User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")
    request = TrainingRequest.create!(
      user: member,
      training_topic: training_topics(:woodworking),
      share_contact_info: true,
      status: 'responded',
      responded_at: Time.current
    )

    post dismiss_training_request_path(request)

    assert_not_nil request.reload.dismissed_at
  end

  test 'member cannot dismiss another members request' do
    sign_in_as_member
    other_request = training_requests(:responded_woodworking_request)

    post dismiss_training_request_path(other_request)

    assert_nil other_request.reload.dismissed_at
    member = User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")
    assert_redirected_to user_path(member)
  end

  test 'member dashboard links to training request page' do
    sign_in_as_member
    member = User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")

    get user_path(member)
    assert_response :success
    assert_match(/Request Training/i, response.body)
    assert_match(new_training_request_path, response.body)
  end

  private

  def sign_in_as_member
    post local_login_path, params: {
      session: { email: local_accounts(:regular_member).email, password: 'memberpassword123' }
    }
  end

  def sign_in_as_trainer
    post local_login_path, params: {
      session: { email: local_accounts(:trainer_account).email, password: 'trainerpassword123' }
    }
    User.find_by(authentik_id: "local:#{local_accounts(:trainer_account).id}")
  end

  def sign_in_as_admin
    post local_login_path, params: {
      session: { email: local_accounts(:active_admin).email, password: 'localpassword123' }
    }
    User.find_by(authentik_id: "local:#{local_accounts(:active_admin).id}")
  end
end
