require 'test_helper'

class AuthentikApplicationGroupMembershipSyncJobTest < ActiveJob::TestCase
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

  test 'syncs Authentik groups that depend on changed source groups' do
    source_group = application_groups(:sample_group)
    source_group.update!(authentik_group_id: nil)

    dependent_group = ApplicationGroup.create!(
      application: applications(:sample_app),
      name: 'Dependent Sync Group',
      authentik_name: 'sample:dependent-sync-group',
      authentik_group_id: 'dependent-authentik-group',
      member_source: 'sync_group',
      sync_with_group: source_group
    )

    nested_dependent_group = ApplicationGroup.create!(
      application: applications(:sample_app),
      name: 'Nested Dependent Sync Group',
      authentik_name: 'sample:nested-dependent-sync-group',
      authentik_group_id: 'nested-dependent-authentik-group',
      member_source: 'sync_group',
      sync_with_group: dependent_group
    )

    fake_client = Class.new do
      class << self
        attr_accessor :requested_group_ids
      end
      self.requested_group_ids = []

      def get_group(group_id)
        self.class.requested_group_ids << group_id
        { 'users' => [] }
      end

      def set_group_users(_group_id, _user_ids); end
    end

    with_stubbed_authentik_client(fake_client) do
      Authentik::ApplicationGroupMembershipSyncJob.perform_now(%w[manual])
    end

    assert_equal [dependent_group.authentik_group_id, nested_dependent_group.authentik_group_id],
                 fake_client.requested_group_ids
  end

  test 'adding a member to a custom core group queues a sync of groups that copy it' do
    core_group = Authentik::CoreGroupProvisioner.system_application.application_groups.create!(
      name: 'Trusted admins',
      authentik_name: 'ctrlh:org:members:trusted-admins',
      member_source: 'manual',
      authentik_group_id: 'core-authentik-group'
    )
    dependent = ApplicationGroup.create!(
      application: applications(:sample_app),
      name: 'App copy of trusted admins',
      authentik_name: 'sample:trusted-admins',
      authentik_group_id: 'app-copy-authentik-group',
      member_source: 'sync_group',
      sync_with_group: core_group
    )

    assert_enqueued_with(job: Authentik::ApplicationGroupMembershipSyncJob, args: [%w[manual]]) do
      core_group.users << users(:one)
    end

    fake_client = Class.new do
      class << self
        attr_accessor :requested_group_ids
      end
      self.requested_group_ids = []

      def get_group(group_id)
        self.class.requested_group_ids << group_id
        { 'users' => [] }
      end

      def set_group_users(_group_id, _user_ids); end
    end

    with_stubbed_authentik_client(fake_client) do
      Authentik::ApplicationGroupMembershipSyncJob.perform_now(%w[manual])
    end

    assert_includes fake_client.requested_group_ids, dependent.authentik_group_id
    assert_includes fake_client.requested_group_ids, core_group.authentik_group_id
  end
end
