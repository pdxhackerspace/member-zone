require 'test_helper'

module Authentik
  class UserSyncTest < ActiveSupport::TestCase
    setup do
      @settings = AuthentikConfig.settings
      @original_api_token = @settings.api_token
      @original_api_base_url = @settings.api_base_url
      @settings.api_token = 'test-token'
      @settings.api_base_url = 'https://authentik.example.test'
    end

    teardown do
      @settings.api_token = @original_api_token
      @settings.api_base_url = @original_api_base_url
    end

    test 'sync_from_authentik records external data without copying fields to user' do
      user = users(:two)
      user.update_columns(
        authentik_id: 'authentik-sync-from-test',
        email: 'memberzone@example.com',
        full_name: 'Member Zone Name',
        username: 'memberzone'
      )

      client = Class.new do
        def get_user(_authentik_id)
          {
            'username' => 'authentikusername',
            'email' => 'authentik@example.com',
            'name' => 'Authentik Name',
            'is_active' => true
          }
        end
      end.new

      result = Authentik::UserSync.new(user, client: client).sync_from_authentik!

      assert_equal 'updated', result[:status]
      authentik_user = AuthentikUser.find_by!(authentik_id: user.authentik_id)
      assert_equal user.id, authentik_user.user_id
      assert_equal 'authentik@example.com', authentik_user.email
      assert_equal 'Authentik Name', authentik_user.full_name
      assert_equal 'authentikusername', authentik_user.username

      user.reload
      assert_equal 'memberzone@example.com', user.email
      assert_equal 'Member Zone Name', user.full_name
      assert_equal 'memberzone', user.username
    end

    test 'sync_to_authentik includes slack fields in attributes' do
      user = users(:two)
      user.update_columns(
        authentik_id: 'authentik-sync-to-test',
        slack_id: 'U123SLACK',
        slack_handle: 'alice'
      )

      captured_attrs = nil
      client = Class.new do
        define_method(:update_user) do |authentik_id, **attrs|
          captured_attrs = attrs
          { 'pk' => authentik_id }
        end
      end.new

      result = Authentik::UserSync.new(user, client: client).sync_to_authentik!

      assert_equal 'synced', result[:status]
      assert_equal(
        {
          'member_zone_id' => user.id.to_s,
          'slack_user_id' => 'U123SLACK',
          'slack_handle' => 'alice',
          'trained_on' => [],
          'can_train' => []
        },
        captured_attrs[:attributes]
      )
    end

    test 'sync_to_authentik syncs slack attribute changes only' do
      user = users(:two)
      user.update_columns(
        authentik_id: 'authentik-slack-only-test',
        slack_id: 'U999SLACK',
        slack_handle: 'bob'
      )

      captured_attrs = nil
      client = Class.new do
        define_method(:update_user) do |authentik_id, **attrs|
          captured_attrs = attrs
          { 'pk' => authentik_id }
        end
      end.new

      result = Authentik::UserSync.new(user, client: client).sync_to_authentik!(changed_fields: %w[slack_id])

      assert_equal 'synced', result[:status]
      assert_equal %w[slack_id], result[:fields]
      assert_equal 'U999SLACK', captured_attrs[:attributes]['slack_user_id']
      assert_empty captured_attrs.except(:attributes)
    end

    test 'sync_to_authentik includes slack fields from linked slack user' do
      user = users(:two)
      slack_user = slack_users(:with_dept)
      user.update_columns(authentik_id: 'authentik-linked-slack-test', slack_id: nil, slack_handle: nil)
      slack_user.update!(user_id: user.id)

      captured_attrs = nil
      client = Class.new do
        define_method(:update_user) do |authentik_id, **attrs|
          captured_attrs = attrs
          { 'pk' => authentik_id }
        end
      end.new

      result = Authentik::UserSync.new(user, client: client).sync_to_authentik!

      assert_equal 'synced', result[:status]
      assert_equal slack_user.slack_id, captured_attrs[:attributes]['slack_user_id']
      assert_equal slack_user.username, captured_attrs[:attributes]['slack_handle']
    end

    test 'sync_to_authentik sends inactive users as active when setting enabled' do
      DefaultSetting.instance.update!(authentik_sync_inactive_as_active: true)
      user = users(:two)
      user.update_columns(authentik_id: 'authentik-inactive-active-test', active: false,
                          membership_state: 'inactive_member')

      captured_attrs = nil
      client = Class.new do
        define_method(:update_user) do |authentik_id, **attrs|
          captured_attrs = attrs
          { 'pk' => authentik_id }
        end
      end.new

      result = Authentik::UserSync.new(user, client: client).sync_to_authentik!(changed_fields: %w[active])

      assert_equal 'synced', result[:status]
      assert_equal true, captured_attrs['is_active']
    end

    test 'sync_to_authentik sends inactive users as inactive when setting disabled' do
      DefaultSetting.instance.update!(authentik_sync_inactive_as_active: false)
      user = users(:two)
      user.update_columns(authentik_id: 'authentik-inactive-inactive-test', active: false,
                          membership_state: 'inactive_member')

      captured_attrs = nil
      client = Class.new do
        define_method(:update_user) do |authentik_id, **attrs|
          captured_attrs = attrs
          { 'pk' => authentik_id }
        end
      end.new

      result = Authentik::UserSync.new(user, client: client).sync_to_authentik!(changed_fields: %w[active])

      assert_equal 'synced', result[:status]
      assert_equal false, captured_attrs['is_active']
    end

    test 'sync_to_authentik includes training attributes' do
      user = users(:one)
      user.update_columns(authentik_id: 'authentik-training-sync-test')
      Training.create!(
        trainee: user,
        trainer: users(:two),
        training_topic: training_topics(:laser_cutting),
        trained_at: Time.current
      )
      TrainerCapability.create!(user: user, training_topic: training_topics(:woodworking))

      captured_attrs = nil
      client = Class.new do
        define_method(:update_user) do |authentik_id, **attrs|
          captured_attrs = attrs
          { 'pk' => authentik_id }
        end
      end.new

      result = Authentik::UserSync.new(user, client: client).sync_to_authentik!(
        changed_fields: %w[trained_on can_train]
      )

      assert_equal 'synced', result[:status]
      assert_equal %w[trained_on can_train], result[:fields]
      assert_equal ['Laser Cutting'], captured_attrs[:attributes]['trained_on']
      assert_equal ['Woodworking'], captured_attrs[:attributes]['can_train']
    end
  end
end
