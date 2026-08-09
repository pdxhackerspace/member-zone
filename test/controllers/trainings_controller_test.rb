require 'test_helper'

class TrainingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
    @laser_topic = training_topics(:laser_cutting)
    @woodworking_topic = training_topics(:woodworking)
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  test 'trainer sees only topics they can train on record page' do
    trainer = sign_in_as_trainer
    TrainerCapability.create!(user: trainer, training_topic: @laser_topic)

    get record_training_path

    assert_response :success
    assert_match 'Laser Cutting', response.body
    assert_no_match 'Woodworking', response.body
    assert_select 'a[href=?]', edit_training_topic_path(@laser_topic), count: 0
    assert_no_match 'Manage Training Topics', response.body
  end

  test 'trainer can add training for a topic they can train' do
    trainer = sign_in_as_trainer
    trainee = users(:no_email)
    TrainerCapability.create!(user: trainer, training_topic: @laser_topic)

    assert_difference 'Training.count', 1 do
      post record_training_path, params: {
        training_topic_id: @laser_topic.id,
        trained_at: Date.current.iso8601,
        trainee_ids: [trainee.id]
      }
    end

    assert_redirected_to training_catalog_path
    assert Training.exists?(trainee: trainee, trainer: trainer, training_topic: @laser_topic)
  end

  test 'trainer cannot add training for a topic they cannot train' do
    trainer = sign_in_as_trainer
    trainee = users(:no_email)
    TrainerCapability.create!(user: trainer, training_topic: @laser_topic)

    assert_no_difference 'Training.count' do
      post record_training_path, params: {
        training_topic_id: @woodworking_topic.id,
        trained_at: Date.current.iso8601,
        trainee_ids: [trainee.id]
      }
    end

    assert_redirected_to record_training_path
  end

  test 'bulk record skips members already trained in topic' do
    trainer = sign_in_as_trainer
    trained_trainee = users(:one)
    new_trainee = users(:no_email)
    TrainerCapability.create!(user: trainer, training_topic: @laser_topic)
    Training.create!(
      trainee: trained_trainee,
      trainer: trainer,
      training_topic: @laser_topic,
      trained_at: 2.days.ago
    )

    assert_difference 'Training.count', 1 do
      post record_training_path, params: {
        training_topic_id: @laser_topic.id,
        trained_at: Date.current.iso8601,
        trainee_ids: [trained_trainee.id, new_trainee.id]
      }
    end

    assert_redirected_to training_catalog_path
    assert_equal 1, Training.where(trainee: trained_trainee, training_topic: @laser_topic).count
    assert Training.exists?(trainee: new_trainee, trainer: trainer, training_topic: @laser_topic)
  end

  test 'admin can backdate training and attribute it to an authorized trainer' do
    sign_in_as_admin
    trainer = users(:one)
    trainee = users(:no_email)
    TrainerCapability.create!(user: trainer, training_topic: @laser_topic)
    trained_on = 45.days.ago.to_date

    assert_difference 'Training.count', 1 do
      post record_training_path, params: {
        training_topic_id: @laser_topic.id,
        trainer_id: trainer.id,
        trained_at: trained_on.iso8601,
        trainee_ids: [trainee.id]
      }
    end

    training = Training.find_by!(trainee: trainee, training_topic: @laser_topic)
    assert_redirected_to training_catalog_path
    assert_equal trainer, training.trainer
    assert_equal trained_on, training.trained_at.to_date
  end

  test 'old train a member path redirects to record page' do
    sign_in_as_admin

    get train_member_path

    assert_redirected_to record_training_path
  end

  test 'regular member cannot access record training' do
    sign_in_as_regular_member

    get record_training_path

    assert_redirected_to root_path
  end

  test 'admin sees trainer capabilities panel on record page' do
    sign_in_as_admin

    get record_training_path

    assert_response :success
    assert_match 'Trainer capabilities', response.body
    assert_match 'Grant or revoke who can train others', response.body
  end

  test 'trainer does not see trainer capabilities panel on record page' do
    trainer = sign_in_as_trainer
    TrainerCapability.create!(user: trainer, training_topic: @laser_topic)

    get record_training_path

    assert_response :success
    assert_no_match 'Trainer capabilities', response.body
    assert_no_match 'trainer-capabilities-panel', response.body
  end

  test 'admin grant trainer capability redirects to record page with state' do
    sign_in_as_admin
    trainee = users(:no_email)

    assert_difference 'TrainerCapability.count', 1 do
      post add_trainer_capability_path(user_id: trainee.id, topic_id: @laser_topic.id),
           params: {
             return_topic_id: @laser_topic.id,
             return_trainee_ids: "#{users(:one).id},#{trainee.id}"
           }
    end

    assert_redirected_to record_training_path(
      trainer_user_id: trainee.id,
      topic_id: @laser_topic.id,
      trainee_ids: "#{users(:one).id},#{trainee.id}"
    )
    follow_redirect!
    assert_response :success
    assert_match trainee.display_name, response.body
  end

  test 'admin grant trainer capability creates capability and training when not trained' do
    sign_in_as_admin
    trainee = users(:no_email)

    assert_difference ['TrainerCapability.count', 'Training.count'], 1 do
      post add_trainer_capability_path(user_id: trainee.id, topic_id: @laser_topic.id)
    end

    assert TrainerCapability.exists?(user: trainee, training_topic: @laser_topic)
    assert Training.exists?(trainee: trainee, training_topic: @laser_topic)
    assert_match 'can now train others', flash[:notice]
  end

  test 'add_training with return_to profile redirects to the member profile training section' do
    sign_in_as_admin
    trainee = users(:no_email)

    assert_difference 'Training.count', 1 do
      post add_training_path(user_id: trainee.id, topic_id: @laser_topic.id, return_to: 'profile')
    end

    assert_redirected_to user_path(trainee.id, anchor: 'training-access-section')
  end

  test 'add_training records an inactive member without emailing them' do
    sign_in_as_admin
    trainee = make_inactive(users(:three))

    assert_difference 'Training.count', 1 do
      assert_no_difference 'training_completed_mail_count(trainee)' do
        post add_training_path(user_id: trainee.id, topic_id: @laser_topic.id, return_to: 'profile')
      end
    end

    assert_match 'no notification was sent', flash[:notice]
  end

  test 'add_training emails an inactive member when the trainer asked for it' do
    sign_in_as_admin
    trainee = make_inactive(users(:three))

    assert_difference 'training_completed_mail_count(trainee)', 1 do
      post add_training_path(user_id: trainee.id, topic_id: @laser_topic.id, return_to: 'profile'),
           params: { notify_inactive: '1' }
    end

    assert_match 'notification was sent anyway', flash[:notice]
  end

  test 'add_training refuses a banned member' do
    sign_in_as_admin
    trainee = users(:three)
    trainee.update!(membership_status: 'banned')

    assert_no_difference 'Training.count' do
      post add_training_path(user_id: trainee.id, topic_id: @laser_topic.id, return_to: 'profile')
    end

    assert_match 'banned', flash[:alert]
  end

  test 'bulk record trains inactive members and reports how they were notified' do
    trainer = sign_in_as_trainer
    inactive = make_inactive(users(:three))
    TrainerCapability.create!(user: trainer, training_topic: @laser_topic)

    assert_difference 'Training.count', 1 do
      post record_training_path, params: {
        training_topic_id: @laser_topic.id,
        trained_at: Date.current.iso8601,
        trainee_ids: [inactive.id],
        notify_inactive: '1'
      }
    end

    assert Training.exists?(trainee: inactive, training_topic: @laser_topic)
    assert_match '1 inactive member trained and notified.', flash[:notice]
  end

  test 'remove_training with return_to profile redirects to the member profile training section' do
    sign_in_as_admin
    trainee = users(:no_email)
    Training.create!(trainee: trainee, trainer: users(:one), training_topic: @laser_topic, trained_at: 1.day.ago)

    assert_difference 'Training.count', -1 do
      delete remove_training_path(user_id: trainee.id, topic_id: @laser_topic.id, return_to: 'profile')
    end

    assert_redirected_to user_path(trainee.id, anchor: 'training-access-section')
  end

  test 'add_trainer_capability with return_to profile redirects to the member profile training section' do
    sign_in_as_admin
    trainee = users(:no_email)

    post add_trainer_capability_path(user_id: trainee.id, topic_id: @laser_topic.id, return_to: 'profile')

    assert_redirected_to user_path(trainee, anchor: 'training-access-section')
  end

  test 'remove_trainer_capability with return_to profile redirects to the member profile training section' do
    sign_in_as_admin
    trainee = users(:no_email)
    TrainerCapability.create!(user: trainee, training_topic: @laser_topic)

    delete remove_trainer_capability_path(user_id: trainee.id, topic_id: @laser_topic.id, return_to: 'profile')

    assert_redirected_to user_path(trainee, anchor: 'training-access-section')
  end

  private

  def make_inactive(user)
    Membership::ActiveStatus.assign_and_save!(user, membership_status: 'paying', dues_status: 'lapsed')
    assert_not user.reload.active?
    user
  end

  def training_completed_mail_count(user)
    QueuedMail.where(recipient: user, mailer_action: 'training_completed').count
  end

  def sign_in_as_admin
    account = local_accounts(:active_admin)
    post local_login_path, params: {
      session: {
        email: account.email,
        password: 'localpassword123'
      }
    }
  end

  def sign_in_as_trainer
    account = local_accounts(:trainer_account)
    post local_login_path, params: {
      session: {
        email: account.email,
        password: 'trainerpassword123'
      }
    }
    User.find_by!(authentik_id: "local:#{account.id}")
  end

  def sign_in_as_regular_member
    account = local_accounts(:regular_member)
    post local_login_path, params: {
      session: {
        email: account.email,
        password: 'memberpassword123'
      }
    }
  end
end
