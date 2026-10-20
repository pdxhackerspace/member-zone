require 'test_helper'

class RfidTest < ActiveJob::TestCase
  teardown do
    Current.reset
  end

  test 'creating a key fob creates a highlighted journal entry' do
    actor = users(:two)
    user = users(:one)
    Current.user = actor

    assert_difference -> { user.journals.count }, 1 do
      Rfid.create!(user: user, rfid: 'RFID-NEW-001', notes: 'Front door fob')
    end

    journal = user.journals.order(:created_at).last
    assert_equal 'key_fob_added', journal.action
    assert_equal actor, journal.actor_user
    assert journal.highlight?
    assert_equal 'RFID-NEW-001', journal.changes_json.dig('key_fob', 'rfid')
    assert_equal 'Front door fob', journal.changes_json.dig('key_fob', 'notes')
  end

  test 'normalizes RFID on assign: strips whitespace and comma spacing regression' do
    user = users(:one)
    Current.user = users(:two)

    rfid = Rfid.create!(user: user, rfid: '7001, 00456842')
    rfid.reload
    assert_equal '7001,456842', rfid.rfid
  end

  test 'destroying a key fob enqueues an access controller sync' do
    rfid = rfids(:one)
    Current.user = users(:two)

    assert_enqueued_with(job: AccessControllerMemberKeysSyncJob, args: [users(:two).id]) do
      rfid.destroy!
    end
  end

  test 'destroying key fobs with a member enqueues a sync for each fob' do
    user = User.create!(
      authentik_id: "rfid-cascade-#{SecureRandom.hex(4)}",
      full_name: 'Rfid cascade',
      email: "rfid-cascade-#{SecureRandom.hex(4)}@example.com",
      membership_state: 'inactive_member'
    )
    Current.user = users(:two)
    user.rfids.create!(rfid: "CAS#{SecureRandom.hex(3)}")
    user.rfids.create!(rfid: "CAS#{SecureRandom.hex(3)}")

    assert_enqueued_jobs 2, only: AccessControllerMemberKeysSyncJob do
      user.destroy!
    end
  end

  test 'destroying a key fob creates a highlighted journal entry' do
    actor = users(:two)
    rfid = rfids(:one)
    user = rfid.user
    Current.user = actor

    assert_difference -> { user.journals.count }, 1 do
      rfid.destroy!
    end

    journal = user.journals.order(:created_at).last
    assert_equal 'key_fob_removed', journal.action
    assert_equal actor, journal.actor_user
    assert journal.highlight?
    assert_equal 'RFID001', journal.changes_json.dig('key_fob', 'rfid')
    assert_equal "User one's card", journal.changes_json.dig('key_fob', 'notes')
  end
end
