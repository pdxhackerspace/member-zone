require 'test_helper'

class TrainingCatalogControllerTest < ActionDispatch::IntegrationTest
  setup do
    @laser_topic       = training_topics(:laser_cutting)
    @woodworking_topic = training_topics(:woodworking)
    @electronics_topic = training_topics(:electronics)

    @original_local_auth_enabled = Rails.application.config.x.local_auth.enabled
    Rails.application.config.x.local_auth.enabled = true
  end

  teardown do
    Rails.application.config.x.local_auth.enabled = @original_local_auth_enabled
  end

  # Index

  test 'unauthenticated user is redirected to login' do
    get training_catalog_path
    assert_response :redirect
  end

  test 'admin sees all training topics including those not offered to members' do
    sign_in_as_admin
    get training_catalog_path

    assert_response :success
    assert_match @laser_topic.name,       response.body
    assert_match @woodworking_topic.name, response.body
    assert_match @electronics_topic.name, response.body
  end

  test 'member sees only topics offered to members' do
    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_match @laser_topic.name,       response.body
    assert_match @woodworking_topic.name, response.body
    assert_no_match(/#{Regexp.escape(@electronics_topic.name)}/, response.body)
  end

  test 'index shows request training button when a requestable topic exists' do
    TrainerCapability.find_or_create_by!(user: users(:one), training_topic: @laser_topic)

    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_match(/Request Training/i, response.body)
    assert_match new_training_request_path, response.body
  end

  test 'index does not show request training button when no topic has a trainer' do
    TrainerCapability.where(training_topic: [@laser_topic, @woodworking_topic]).delete_all

    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_no_match(/Request Training/i, response.body)
  end

  test 'index does not show request training button when only trainers are inactive' do
    TrainerCapability.where(training_topic: [@laser_topic, @woodworking_topic]).delete_all
    inactive_trainer = users(:two)
    inactive_trainer.update!(membership_state: 'inactive_member')
    TrainerCapability.find_or_create_by!(user: inactive_trainer, training_topic: @laser_topic)

    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_no_match(/Request Training/i, response.body)
  end

  test 'admin index marks whether each topic is offered to members' do
    sign_in_as_admin
    get training_catalog_path

    assert_response :success
    assert_match(/Offered/i, response.body)
  end

  test 'admin index links to record training' do
    sign_in_as_admin
    get training_catalog_path

    assert_response :success
    assert_match(/Record training/i, response.body)
    assert_match record_training_path, response.body
  end

  test 'member index does not link to record training' do
    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_no_match record_training_path, response.body
  end

  # Show

  test 'member can view a topic that is offered to members' do
    TrainerCapability.find_or_create_by!(user: users(:one), training_topic: @laser_topic)

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match @laser_topic.name, response.body
    assert_match(/Trainers/i, response.body)
    assert_match(/Trained Members/i, response.body)
    assert_match(/Training Materials/i, response.body)
  end

  test 'member cannot view a topic that is not offered to members' do
    sign_in_as_member
    get training_catalog_topic_path(@electronics_topic)

    assert_redirected_to training_catalog_path
    assert_equal 'That training topic is not available.', flash[:alert]
  end

  test 'admin can view a topic that is not offered to members' do
    sign_in_as_admin
    get training_catalog_topic_path(@electronics_topic)

    assert_response :success
    assert_match @electronics_topic.name, response.body
  end

  test 'show lists trainers and trainees for the topic' do
    trainer = users(:one)
    trainee = users(:two)
    TrainerCapability.find_or_create_by!(user: trainer, training_topic: @laser_topic)
    Training.find_or_create_by!(trainee: trainee, training_topic: @laser_topic) do |t|
      t.trainer    = trainer
      t.trained_at = Time.current
    end

    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match trainer.display_name, response.body
    assert_match trainee.display_name, response.body
  end

  test 'show lists training topic links' do
    link = training_topic_links(:laser_safety_guide)

    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match link.title, response.body
    assert_match link.url, response.body
  end

  test 'show displays request training button for a trainable topic' do
    TrainerCapability.find_or_create_by!(user: users(:one), training_topic: @laser_topic)

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match(/Request Training/i, response.body)
    assert_match new_training_request_path, response.body
  end

  test 'show does not display request training button when topic has no trainer' do
    TrainerCapability.where(training_topic: @laser_topic).delete_all

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_no_match(/Request Training/i, response.body)
  end

  test 'show lists inactive trainers for admins but not for members' do
    active_trainer   = users(:one)
    inactive_trainer = users(:two)
    inactive_trainer.update!(membership_state: 'inactive_member')
    TrainerCapability.find_or_create_by!(user: active_trainer,   training_topic: @laser_topic)
    TrainerCapability.find_or_create_by!(user: inactive_trainer, training_topic: @laser_topic)

    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match active_trainer.display_name, response.body
    assert_match inactive_trainer.display_name, response.body
    assert_match 'Inactive', response.body

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match active_trainer.display_name, response.body
    assert_no_match(/#{Regexp.escape(inactive_trainer.display_name)}/, response.body)
  end

  test 'show marks inactive trained members for admins' do
    trainer = users(:one)
    inactive_trainee = users(:two)
    inactive_trainee.update!(membership_state: 'inactive_member')
    TrainerCapability.find_or_create_by!(user: trainer, training_topic: @laser_topic)
    Training.find_or_create_by!(trainee: inactive_trainee, training_topic: @laser_topic) do |t|
      t.trainer = trainer
      t.trained_at = Time.current
    end

    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match inactive_trainee.display_name, response.body
    assert_match 'Inactive', response.body
  end

  test 'admin index shows trainer and trained counts split by active status' do
    active_trainer = users(:one)
    inactive_trainer = users(:two)
    inactive_trainer.update!(membership_state: 'inactive_member')
    inactive_trainee = users(:no_email)
    inactive_trainee.update!(membership_state: 'inactive_member')

    TrainerCapability.find_or_create_by!(user: active_trainer, training_topic: @laser_topic)
    TrainerCapability.find_or_create_by!(user: inactive_trainer, training_topic: @laser_topic)
    Training.find_or_create_by!(trainee: inactive_trainee, training_topic: @laser_topic) do |t|
      t.trainer = active_trainer
      t.trained_at = Time.current
    end

    sign_in_as_admin
    get training_catalog_path

    assert_response :success
    laser_link = css_select("a[href='#{training_catalog_topic_path(@laser_topic)}']").first
    row_text = laser_link.ancestors('tr').first.text.squish
    assert_includes row_text, '2'
    assert_includes row_text, '1 active'
    assert_includes row_text, '1 inactive'
  end

  test 'needs trainers filter ignores topics with only inactive trainers' do
    inactive_trainer = users(:two)
    inactive_trainer.update!(membership_state: 'inactive_member')
    TrainerCapability.where(training_topic: @laser_topic).delete_all
    TrainerCapability.find_or_create_by!(user: inactive_trainer, training_topic: @laser_topic)

    sign_in_as_admin
    get training_catalog_path(training_filter: 'needs_trainers')

    assert_response :success
    assert_match @laser_topic.name, response.body
  end

  test 'show does not display request training button when only trainers are inactive' do
    inactive_trainer = users(:two)
    inactive_trainer.update!(membership_state: 'inactive_member')
    TrainerCapability.where(training_topic: @laser_topic).delete_all
    TrainerCapability.find_or_create_by!(user: inactive_trainer, training_topic: @laser_topic)

    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_no_match(/Request Training/i, response.body)
  end

  test 'show renders training materials before trainers and trained members' do
    TrainerCapability.find_or_create_by!(user: users(:one), training_topic: @laser_topic)

    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    materials_index = response.body.index('Training Materials')
    trainers_index  = response.body.index('Trainers</h2>')
    trained_index   = response.body.index('Trained Members')

    assert materials_index, 'expected Training Materials section'
    assert trainers_index,  'expected Trainers section'
    assert trained_index,   'expected Trained Members section'
    assert materials_index < trainers_index,
           'expected Training Materials to appear before Trainers'
    assert materials_index < trained_index,
           'expected Training Materials to appear before Trained Members'
  end

  test 'show displays edit button for admin' do
    sign_in_as_admin
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_match edit_training_topic_path(@laser_topic), response.body
    assert_match(/>\s*Edit\s*</, response.body)
  end

  test 'show does not display edit button for non-admin' do
    sign_in_as_member
    get training_catalog_topic_path(@laser_topic)

    assert_response :success
    assert_no_match(/#{Regexp.escape(edit_training_topic_path(@laser_topic))}/, response.body)
  end

  test 'show returns friendly error for unknown topic' do
    sign_in_as_admin
    get training_catalog_topic_path(id: 999_999_999)

    assert_redirected_to training_catalog_path
    assert_equal 'Training topic not found.', flash[:alert]
  end

  # Navbar

  test 'navbar includes training link for admin' do
    sign_in_as_admin
    get root_path

    assert_response :success
    assert_match(%r{>Training</a>}, response.body)
    assert_match training_catalog_path, response.body
  end

  test 'navbar includes training link for member' do
    sign_in_as_member
    get training_catalog_path

    assert_response :success
    assert_match(%r{>Training</a>}, response.body)
    assert_match training_catalog_path, response.body
  end

  test 'navbar shows dashboard shortcut icon for non-admin member' do
    sign_in_as_member
    member = User.find_by(authentik_id: "local:#{local_accounts(:regular_member).id}")

    get training_catalog_path

    assert_response :success
    assert_match(/aria-label="Dashboard"/, response.body)
    assert_match(/bi bi-speedometer2/, response.body)
    assert_match user_path(member, tab: :dashboard), response.body
  end

  test 'navbar shows home icon for admin rather than dashboard shortcut' do
    sign_in_as_admin
    get root_path

    assert_response :success
    assert_match(/aria-label="Home"/, response.body)
    assert_no_match(/aria-label="Dashboard"/, response.body)
  end

  private

  def sign_in_as_admin
    post local_login_path, params: {
      session: { email: local_accounts(:active_admin).email, password: 'localpassword123' }
    }
  end

  def sign_in_as_member
    post local_login_path, params: {
      session: { email: local_accounts(:regular_member).email, password: 'memberpassword123' }
    }
  end
end
