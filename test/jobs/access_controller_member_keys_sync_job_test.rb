require 'test_helper'

class AccessControllerMemberKeysSyncJobTest < ActiveJob::TestCase
  setup do
    @door_type = access_controller_types(:door_lock)
    @disabled_type = access_controller_types(:disabled_type)
    @door = AccessController.create!(name: 'Door sync test', hostname: 'door-sync.local',
                                     access_controller_type: @door_type)
    @door_disabled = AccessController.create!(name: 'Door off', hostname: 'door-off.local',
                                              access_controller_type: @door_type, enabled: false)
    AccessController.create!(name: 'Disabled type', hostname: 'dtype.local',
                             access_controller_type: @disabled_type)
  end

  test 'enqueues sync on every enabled controller with an enabled type' do
    assert_enqueued_jobs 1, only: AccessControllerVerbJob do
      AccessControllerMemberKeysSyncJob.perform_now(users(:two).id)
    end

    assert_enqueued_with(job: AccessControllerVerbJob, args: [@door.id, 'sync', users(:two).id])
  end

  test 'does nothing when no syncable controllers exist' do
    AccessController.delete_all

    assert_no_enqueued_jobs only: AccessControllerVerbJob do
      AccessControllerMemberKeysSyncJob.perform_now
    end
  end
end
