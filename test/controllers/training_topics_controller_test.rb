require 'test_helper'

class TrainingTopicsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @laser_topic = training_topics(:laser_cutting)
    @woodworking_topic = training_topics(:woodworking)
    ENV['LOCAL_AUTH_ENABLED'] = 'true'
  end

  teardown do
    ENV.delete('LOCAL_AUTH_ENABLED')
  end

  # ─── Helper methods ───────────────────────────────────────────────────

  def sign_in_as_admin
    Rails.application.config.x.local_auth.enabled = true
    post local_login_path, params: {
      session: { email: 'admin@example.com', password: 'localpassword123' }
    }
    User.find_by('authentik_id LIKE ?', 'local:%')&.tap { |u| u.update!(is_admin: true) }
  end

  def sign_in_as_trainer
    Rails.application.config.x.local_auth.enabled = true
    post local_login_path, params: {
      session: { email: 'trainer@example.com', password: 'trainerpassword123' }
    }
    user = User.find_by('authentik_id LIKE ?', "local:#{local_accounts(:trainer_account).id}")
    TrainerCapability.find_or_create_by!(user: user, training_topic: @laser_topic)
    user
  end

  def sign_in_as_regular_member
    Rails.application.config.x.local_auth.enabled = true
    post local_login_path, params: {
      session: { email: 'member@example.com', password: 'memberpassword123' }
    }
  end

  # ─── Not signed in ────────────────────────────────────────────────────

  test 'unauthenticated user cannot access training topics index' do
    get training_topics_path
    assert_redirected_to login_path
  end

  test 'unauthenticated user cannot access training topic edit' do
    get edit_training_topic_path(@laser_topic)
    assert_redirected_to login_path
  end

  # ─── Admin access ─────────────────────────────────────────────────────

  test 'admin can access training topics index' do
    sign_in_as_admin
    get training_topics_path
    assert_response :success
  end

  test 'admin can access edit for any topic' do
    sign_in_as_admin
    get edit_training_topic_path(@laser_topic)
    assert_response :success

    get edit_training_topic_path(@woodworking_topic)
    assert_response :success
  end

  test 'topic page train action does not ask which trainer' do
    sign_in_as_admin

    get edit_training_topic_path(@laser_topic)

    assert_response :success
    assert_select '#profile-add-training-trainer', count: 0
    assert_select '#record-trainer-id', count: 0
    assert_select 'input[name=trainer_id]', count: 0
    train_path = add_training_path(user_id: users(:no_email).id, topic_id: @laser_topic.id, return_to: 'topic')
    assert_select 'form[action=?]', train_path
  end

  test 'admin can create a training topic' do
    sign_in_as_admin
    assert_difference 'TrainingTopic.count', 1 do
      post training_topics_path, params: {
        training_topic: { name: 'New Topic', offered_to_members: '1' }
      }
    end
    assert_redirected_to training_topics_path
    assert TrainingTopic.find_by(name: 'New Topic').offered_to_members?
  end

  test 'admin can update (rename) a topic' do
    sign_in_as_admin
    patch training_topic_path(@laser_topic), params: {
      training_topic: { name: 'Advanced Laser Cutting', offered_to_members: '0' }
    }
    assert_redirected_to edit_training_topic_path(@laser_topic)
    @laser_topic.reload
    assert_equal 'Advanced Laser Cutting', @laser_topic.name
    assert_not @laser_topic.offered_to_members?
  end

  test 'admin can destroy a topic with no trainings or capabilities' do
    sign_in_as_admin
    topic = TrainingTopic.create!(name: 'Temporary Topic')
    assert_difference 'TrainingTopic.count', -1 do
      delete training_topic_path(topic)
    end
    assert_redirected_to training_topics_path
  end

  test 'admin can revoke training' do
    sign_in_as_admin
    user = users(:one)
    Training.create!(trainee: user, training_topic: @laser_topic, trained_at: Time.current)

    assert_difference 'Training.count', -1 do
      delete revoke_training_training_topic_path(@laser_topic, user_id: user.id)
    end
    assert_redirected_to edit_training_topic_path(@laser_topic)
  end

  test 'admin training revocation queues trained-in Authentik group sync' do
    sign_in_as_admin
    user = users(:one)
    Training.create!(trainee: user, training_topic: @laser_topic, trained_at: Time.current)

    assert_enqueued_with(job: Authentik::ApplicationGroupMembershipSyncJob, args: [%w[trained_in]]) do
      delete revoke_training_training_topic_path(@laser_topic, user_id: user.id)
    end
  end

  test 'admin can revoke trainer capability' do
    sign_in_as_admin
    user = users(:one)
    TrainerCapability.create!(user: user, training_topic: @laser_topic)

    assert_difference 'TrainerCapability.count', -1 do
      delete revoke_trainer_capability_training_topic_path(@laser_topic, user_id: user.id)
    end
    assert_redirected_to edit_training_topic_path(@laser_topic)
  end

  # ─── Trainer access ───────────────────────────────────────────────────

  test 'trainer cannot access edit for their topic' do
    sign_in_as_trainer
    get edit_training_topic_path(@laser_topic)
    assert_response :redirect
  end

  test 'trainer cannot access edit for a topic they do not train' do
    sign_in_as_trainer
    get edit_training_topic_path(@woodworking_topic)
    assert_response :redirect
  end

  test 'trainer cannot access training topics index' do
    sign_in_as_trainer
    get training_topics_path
    # Should redirect because index requires admin
    assert_response :redirect
    follow_redirect!
    assert_not_equal training_topics_path, path
  end

  test 'trainer cannot create a training topic' do
    sign_in_as_trainer
    assert_no_difference 'TrainingTopic.count' do
      post training_topics_path, params: {
        training_topic: { name: 'Unauthorized Topic' }
      }
    end
    assert_response :redirect
  end

  test 'trainer cannot rename a topic via update' do
    sign_in_as_trainer
    original_name = @laser_topic.name
    patch training_topic_path(@laser_topic), params: {
      training_topic: { name: 'Hacked Name' }
    }
    @laser_topic.reload
    assert_response :redirect
    assert_equal original_name, @laser_topic.name
  end

  test 'trainer cannot destroy a topic' do
    sign_in_as_trainer
    assert_no_difference 'TrainingTopic.count' do
      delete training_topic_path(@laser_topic)
    end
    assert_response :redirect
  end

  test 'trainer cannot revoke trainer capability' do
    sign_in_as_trainer
    user = users(:one)
    TrainerCapability.create!(user: user, training_topic: @laser_topic)

    assert_no_difference 'TrainerCapability.count' do
      delete revoke_trainer_capability_training_topic_path(@laser_topic, user_id: user.id)
    end
    assert_response :redirect
  end

  test 'trainer cannot revoke training through training topic edit workflow' do
    trainer_user = sign_in_as_trainer
    trainee = users(:one)
    Training.create!(trainee: trainee, trainer: trainer_user, training_topic: @laser_topic, trained_at: Time.current)

    assert_no_difference 'Training.count' do
      delete revoke_training_training_topic_path(@laser_topic, user_id: trainee.id)
    end
    assert_response :redirect
  end

  test 'trainer cannot revoke training for a topic they do not train' do
    sign_in_as_trainer
    trainee = users(:one)
    Training.create!(trainee: trainee, training_topic: @woodworking_topic, trained_at: Time.current)

    assert_no_difference 'Training.count' do
      delete revoke_training_training_topic_path(@woodworking_topic, user_id: trainee.id)
    end
    assert_response :redirect
  end

  # ─── Regular member access ────────────────────────────────────────────

  test 'regular member cannot access training topics index' do
    sign_in_as_regular_member
    get training_topics_path
    assert_response :redirect
  end

  test 'regular member cannot access training topic edit' do
    sign_in_as_regular_member
    get edit_training_topic_path(@laser_topic)
    assert_response :redirect
  end

  test 'regular member cannot create a training topic' do
    sign_in_as_regular_member
    assert_no_difference 'TrainingTopic.count' do
      post training_topics_path, params: {
        training_topic: { name: 'Unauthorized Topic' }
      }
    end
    assert_response :redirect
  end

  test 'regular member cannot destroy a training topic' do
    sign_in_as_regular_member
    assert_no_difference 'TrainingTopic.count' do
      delete training_topic_path(@laser_topic)
    end
    assert_response :redirect
  end

  # ─── Admin edit page shows all sections ────────────────────────────────

  test 'admin edit page shows topic rename form' do
    sign_in_as_admin
    get edit_training_topic_path(@laser_topic)
    assert_response :success
    assert_match 'Topic Settings', response.body
    assert_match 'Update Topic', response.body
  end

  test 'admin edit page shows trainers list' do
    sign_in_as_admin
    get edit_training_topic_path(@laser_topic)
    assert_response :success
    assert_match 'Users Who Can Train This Topic', response.body
  end

  test 'admin edit page shows danger zone' do
    sign_in_as_admin
    get edit_training_topic_path(@laser_topic)
    assert_response :success
    assert_match 'Danger Zone', response.body
  end
end
