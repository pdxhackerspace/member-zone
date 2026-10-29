require 'test_helper'

class AccessControllerTypesControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV['LOCAL_AUTH_ENABLED'] = 'true'
    sign_in_as_admin

    @door_lock = access_controller_types(:door_lock)
    @laser_controller = access_controller_types(:laser_controller)
    @laser_topic = training_topics(:laser_cutting)
    @woodworking_topic = training_topics(:woodworking)
  end

  teardown do
    ENV.delete('LOCAL_AUTH_ENABLED')
  end

  # --- Index ---

  test 'index shows required training topics' do
    get access_controller_types_url
    assert_response :success
    assert_select 'span.badge', text: 'Laser Cutting'
  end

  # --- Edit ---

  test 'edit shows training topic checkboxes' do
    get edit_access_controller_type_url(@door_lock)
    assert_response :success
    assert_select 'input[type=checkbox][value=?]', @laser_topic.id.to_s
    assert_select 'input[type=checkbox][value=?]', @woodworking_topic.id.to_s
  end

  test 'edit shows existing topics as checked' do
    get edit_access_controller_type_url(@laser_controller)
    assert_response :success
    assert_select "input[type=checkbox][value='#{@laser_topic.id}'][checked]"
  end

  # --- Update ---

  test 'update can assign training topics' do
    assert_empty @door_lock.required_training_topics

    patch access_controller_type_url(@door_lock), params: {
      access_controller_type: {
        name: @door_lock.name,
        script_path: @door_lock.script_path,
        enabled: true,
        required_training_topic_ids: [@laser_topic.id, @woodworking_topic.id]
      }
    }

    assert_redirected_to access_controller_types_path
    @door_lock.reload
    assert_equal 2, @door_lock.required_training_topics.count
    assert_includes @door_lock.required_training_topic_ids, @laser_topic.id
    assert_includes @door_lock.required_training_topic_ids, @woodworking_topic.id
  end

  test 'update can remove all training topics' do
    assert @laser_controller.required_training_topics.any?

    patch access_controller_type_url(@laser_controller), params: {
      access_controller_type: {
        name: @laser_controller.name,
        script_path: @laser_controller.script_path,
        enabled: true,
        required_training_topic_ids: ['']
      }
    }

    assert_redirected_to access_controller_types_path
    @laser_controller.reload
    assert_empty @laser_controller.required_training_topics
  end

  # --- Create ---

  test 'create can assign training topics' do
    assert_difference 'AccessControllerType.count', 1 do
      post access_controller_types_url, params: {
        access_controller_type: {
          name: 'New Type',
          script_path: access_script('new.sh'),
          enabled: true,
          required_training_topic_ids: [@woodworking_topic.id]
        }
      }
    end

    new_type = AccessControllerType.find_by(name: 'New Type')
    assert_equal [@woodworking_topic.id], new_type.required_training_topic_ids
  end

  # --- New ---

  test 'new shows training topic checkboxes' do
    get new_access_controller_type_url
    assert_response :success
    assert_select 'input[type=checkbox][value=?]', @laser_topic.id.to_s
  end

  private

  def sign_in_as_admin
    Rails.application.config.x.local_auth.enabled = true
    post local_login_path, params: {
      session: { email: 'admin@example.com', password: 'localpassword123' }
    }
    User.find_by('authentik_id LIKE ?', 'local:%')&.tap { |u| u.update!(is_admin: true) }
  end
end
