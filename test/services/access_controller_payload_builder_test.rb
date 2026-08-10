require 'test_helper'

class AccessControllerPayloadBuilderTest < ActiveSupport::TestCase
  setup do
    @user_one = users(:one)
    @user_two = users(:two)
    @laser_controller = access_controller_types(:laser_controller)
    @door_lock = access_controller_types(:door_lock)
    @laser_topic = training_topics(:laser_cutting)
    @woodworking_topic = training_topics(:woodworking)
  end

  # --- Global active/inactive filtering ---

  test 'only includes active users by default' do
    payload = parse_payload
    uids = payload.pluck('uid')

    active_with_rfids = User.active.joins(:rfids).distinct
    active_with_rfids.each do |user|
      assert_includes uids, (user.authentik_id.presence || user.id),
                      "Expected active user #{user.display_name} in payload"
    end
  end

  test 'excludes inactive users by default' do
    @user_one.update!(membership_state: 'inactive_member')

    payload = parse_payload
    uids = payload.pluck('uid')
    assert_not_includes uids, @user_one.authentik_id
  end

  test 'includes inactive users when sync_inactive_members is enabled' do
    @user_one.update!(membership_state: 'inactive_member')
    DefaultSetting.instance.update!(sync_inactive_members: true)

    payload = parse_payload
    uids = payload.pluck('uid')
    assert_includes uids, @user_one.authentik_id
  end

  test 'excludes users without RFID cards regardless of active status' do
    @user_one.rfids.destroy_all

    payload = parse_payload
    uids = payload.pluck('uid')
    assert_not_includes uids, @user_one.authentik_id
  end

  # --- Paused key access filtering ---

  test 'excludes members with paused key access even when active with RFIDs' do
    @user_one.pause_key_access!

    payload = parse_payload
    uids = payload.pluck('uid')
    assert_not_includes uids, @user_one.authentik_id
    assert_includes uids, @user_two.authentik_id
  end

  test 'excludes paused members even when sync_inactive_members is enabled' do
    DefaultSetting.instance.update!(sync_inactive_members: true)
    @user_one.pause_key_access!

    payload = parse_payload
    uids = payload.pluck('uid')
    assert_not_includes uids, @user_one.authentik_id
  end

  test 'includes a member again after their key access is resumed' do
    # Keep the member eligible regardless of computed active status so the test
    # isolates the pause/resume behavior.
    DefaultSetting.instance.update!(sync_inactive_members: true)

    @user_one.pause_key_access!
    assert_not_includes parse_payload.pluck('uid'), @user_one.authentik_id

    @user_one.resume_key_access!
    assert_includes parse_payload.pluck('uid'), @user_one.authentik_id
  end

  # --- Per-type training topic filtering ---

  test 'includes all users when no training topics required' do
    # door_lock has no required topics
    payload = parse_payload(access_controller_type: @door_lock)
    uids = payload.pluck('uid')

    assert_includes uids, @user_one.authentik_id
    assert_includes uids, @user_two.authentik_id
  end

  test 'only includes users trained in required topics' do
    # laser_controller requires laser_cutting (via fixture)
    # Train user_one in laser cutting
    Training.create!(trainee: @user_one, training_topic: @laser_topic, trained_at: 1.day.ago)

    payload = parse_payload(access_controller_type: @laser_controller)
    uids = payload.pluck('uid')

    assert_includes uids, @user_one.authentik_id
    assert_not_includes uids, @user_two.authentik_id
  end

  test 'requires ALL topics when multiple are set' do
    # Add woodworking as a second requirement for laser_controller
    @laser_controller.required_training_topics << @woodworking_topic

    # Train user_one in laser cutting only (not woodworking)
    Training.create!(trainee: @user_one, training_topic: @laser_topic, trained_at: 1.day.ago)

    payload = parse_payload(access_controller_type: @laser_controller)
    uids = payload.pluck('uid')
    assert_not_includes uids, @user_one.authentik_id,
                        'User trained in only one of two required topics should be excluded'

    # Now train user_one in woodworking too
    Training.create!(trainee: @user_one, training_topic: @woodworking_topic, trained_at: 1.day.ago)

    payload = parse_payload(access_controller_type: @laser_controller)
    uids = payload.pluck('uid')
    assert_includes uids, @user_one.authentik_id, 'User trained in both required topics should be included'
  end

  test 'no type passed includes all active users with RFIDs' do
    # When called without an access_controller_type, no training filter is applied
    payload = parse_payload(access_controller_type: nil)
    uids = payload.pluck('uid')

    assert_includes uids, @user_one.authentik_id
    assert_includes uids, @user_two.authentik_id
  end

  test 'payload includes permissions for each user' do
    Training.create!(trainee: @user_one, training_topic: @laser_topic, trained_at: 1.day.ago)
    Training.create!(trainee: @user_one, training_topic: @woodworking_topic, trained_at: 1.day.ago)

    payload = parse_payload
    user_entry = payload.find { |u| u['uid'] == @user_one.authentik_id }

    assert_includes user_entry['permissions'], 'Laser Cutting'
    assert_includes user_entry['permissions'], 'Woodworking'
  end

  test 'payload converts user names to ASCII' do
    ensure_user_one_in_payload!
    @user_one.update!(full_name: 'José García', username: 'josé', greeting_name: 'José',
                      use_full_name_for_greeting: false, use_username_for_greeting: false)
    Training.create!(trainee: @user_one, training_topic: @laser_topic, trained_at: 1.day.ago)

    payload = parse_payload
    user_entry = payload.find { |u| u['uid'] == @user_one.authentik_id }

    assert user_entry, 'Expected user_one in payload'
    assert_equal 'Jose Garcia', user_entry['name']
    assert_equal 'Jose', user_entry['greeting_name']
  end

  test 'payload omits greeting_name when it cannot be represented in ASCII' do
    ensure_user_one_in_payload!
    @user_one.update!(full_name: 'Example User One', greeting_name: '用户', use_full_name_for_greeting: false,
                      use_username_for_greeting: false)

    payload = parse_payload
    user_entry = payload.find { |u| u['uid'] == @user_one.authentik_id }

    assert user_entry, 'Expected user_one in payload'
    assert_nil user_entry['greeting_name']
  end

  # --- Model method tests ---

  test 'user_meets_training_requirements? returns true when no topics required' do
    assert @door_lock.user_meets_training_requirements?(@user_one)
  end

  test 'user_meets_training_requirements? returns false when user lacks training' do
    assert_not @laser_controller.user_meets_training_requirements?(@user_one)
  end

  test 'user_meets_training_requirements? returns true when user has required training' do
    Training.create!(trainee: @user_one, training_topic: @laser_topic, trained_at: 1.day.ago)
    assert @laser_controller.user_meets_training_requirements?(@user_one)
  end

  private

  def ensure_user_one_in_payload!
    DefaultSetting.instance.update!(sync_inactive_members: false)
    @user_one.update_columns(
      active: true,
      key_access_paused: false,
      membership_state: 'current_member'
    )
    return if @user_one.rfids.exists?

    @user_one.rfids.create!(rfid: 'RFID001')
  end

  def parse_payload(access_controller_type: nil)
    json = AccessControllerPayloadBuilder.call(access_controller_type: access_controller_type)
    JSON.parse(json)
  end
end
