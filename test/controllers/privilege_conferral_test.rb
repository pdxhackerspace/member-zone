require 'test_helper'

# The no-escalation rule: conferring training or trainer capability hands over the topic's
# privileges, so the actor must already hold every global privilege being conferred.
class PrivilegeConferralTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true

    @privileged_topic = training_topics(:laser_cutting)
    @plain_topic = training_topics(:woodworking)
    @trainee = users(:no_email)

    @privilege = Privilege.create!(key: 'test.keys', label: 'Manage keys', privilege_scope: 'global')
    @grant_trainer = Privilege.create!(key: 'training.grant_trainer', label: 'Grant trainer')
    @role = Role.create!(name: 'Key holder', privileges: [@privilege])
    TrainingTopicRole.create!(training_topic: @privileged_topic, role: @role, member_source: 'trained_in')
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'trainer cannot record training that would confer privileges they lack' do
    trainer = sign_in_as_trainer
    TrainerCapability.create!(user: trainer, training_topic: @privileged_topic)

    assert_no_difference 'Training.count' do
      record_training_for(@privileged_topic)
    end

    assert_redirected_to record_training_path
  end

  test 'trainer holding the conferred privilege can record training' do
    trainer = sign_in_as_trainer
    TrainerCapability.create!(user: trainer, training_topic: @privileged_topic)
    Training.create!(trainee: trainer, training_topic: @privileged_topic, trained_at: 1.day.ago)

    assert_difference 'Training.count', 1 do
      record_training_for(@privileged_topic)
    end

    assert Training.exists?(trainee: @trainee, training_topic: @privileged_topic)
  end

  test 'containment does not restrict topics that carry no roles' do
    trainer = sign_in_as_trainer
    TrainerCapability.create!(user: trainer, training_topic: @plain_topic)

    assert_difference 'Training.count', 1 do
      record_training_for(@plain_topic)
    end
  end

  test 'admins bypass containment' do
    sign_in_as_admin

    assert_difference 'Training.count', 1 do
      record_training_for(@privileged_topic)
    end
  end

  test 'quick add training is blocked by containment' do
    trainer = sign_in_as_trainer
    TrainerCapability.create!(user: trainer, training_topic: @privileged_topic)

    assert_no_difference 'Training.count' do
      post add_training_path(user_id: @trainee.id, topic_id: @privileged_topic.id)
    end
  end

  test 'marking a request trained is blocked by containment' do
    trainer = sign_in_as_trainer
    TrainerCapability.create!(user: trainer, training_topic: @privileged_topic)
    request = TrainingRequest.create!(user: @trainee, training_topic: @privileged_topic)

    assert_no_difference 'Training.count' do
      post mark_trained_training_request_path(request)
    end

    assert_redirected_to user_path(trainer)
  end

  test 'granting trainer capability needs the grant_trainer privilege' do
    trainer = sign_in_as_trainer
    TrainerCapability.create!(user: trainer, training_topic: @plain_topic)

    assert_no_difference 'TrainerCapability.count' do
      post add_trainer_capability_path(user_id: @trainee.id, topic_id: @plain_topic.id)
    end
  end

  test 'grant_trainer holder can appoint a trainer for a topic carrying no roles' do
    trainer = sign_in_as_trainer
    grant_privilege_to(trainer, @grant_trainer)

    assert_difference 'TrainerCapability.count', 1 do
      post add_trainer_capability_path(user_id: @trainee.id, topic_id: @plain_topic.id)
    end
  end

  test 'grant_trainer holder cannot appoint a trainer for a topic conferring privileges they lack' do
    trainer = sign_in_as_trainer
    grant_privilege_to(trainer, @grant_trainer)

    assert_no_difference 'TrainerCapability.count' do
      post add_trainer_capability_path(user_id: @trainee.id, topic_id: @privileged_topic.id)
    end
  end

  test 'grant_trainer holder can appoint a trainer once they hold the conferred privileges' do
    trainer = sign_in_as_trainer
    grant_privilege_to(trainer, @grant_trainer)
    Training.create!(trainee: trainer, training_topic: @privileged_topic, trained_at: 1.day.ago)

    assert_difference 'TrainerCapability.count', 1 do
      post add_trainer_capability_path(user_id: @trainee.id, topic_id: @privileged_topic.id)
    end
  end

  test 'a director who trains nothing can still reach the record page to appoint trainers' do
    director = sign_in_as_member_user
    grant_privilege_to(director, @grant_trainer)

    get record_training_path

    assert_response :success
  end

  private

  def record_training_for(topic)
    post record_training_path, params: {
      training_topic_id: topic.id,
      trained_at: Date.current.iso8601,
      trainee_ids: [@trainee.id]
    }
  end

  # Confers a privilege the only way the system allows: through a role on a topic the member holds.
  def grant_privilege_to(user, privilege)
    topic = TrainingTopic.create!(name: "Grantor for #{privilege.key} #{user.id}", offered_to_members: false)
    role = Role.create!(name: "Grantor role #{privilege.key} #{user.id}", privileges: [privilege])
    TrainingTopicRole.create!(training_topic: topic, role: role, member_source: 'trained_in')
    Training.create!(trainee: user, training_topic: topic, trained_at: 1.day.ago)
    user.reset_privilege_cache!
  end

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: { session: { email: account.email, password: 'localpassword123' } }
    User.find_by!(authentik_id: "local:#{account.id}")
  end

  def sign_in_as_trainer
    account = local_accounts(:trainer_account)
    post local_login_path, params: { session: { email: account.email, password: 'trainerpassword123' } }
    User.find_by!(authentik_id: "local:#{account.id}")
  end

  def sign_in_as_member_user
    account = local_accounts(:regular_member)
    post local_login_path, params: { session: { email: account.email, password: 'memberpassword123' } }
    User.find_by!(authentik_id: "local:#{account.id}")
  end
end
