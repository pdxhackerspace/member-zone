require 'test_helper'
require Rails.root.join('db/migrate/20261106120000_subscribe_opted_in_members_to_all_announcers')

# Members who switched announcements on without ticking an announcer get every enabled one;
# anyone who already chose is left alone.
class SubscribeOptedInMembersToAllAnnouncersTest < ActiveSupport::TestCase
  setup do
    @slack = create_announcer(name: 'Slack')
    @sign = create_announcer(name: 'Sign')
    @retired = create_announcer(name: 'Retired', enabled: false)
  end

  def migrate_up
    migration = SubscribeOptedInMembersToAllAnnouncers.new
    migration.verbose = false
    migration.migrate(:up)
  end

  test 'a member with announcements on and nothing ticked gets every enabled announcer' do
    forgot = users(:one)
    forgot.update!(announce_arrivals: true)

    migrate_up

    assert_equal [@slack, @sign].map(&:id).sort, forgot.reload.announcer_ids.sort
  end

  test 'a member whose only choice is a disabled announcer is treated as having none' do
    member = users(:one)
    member.update!(announce_arrivals: true)
    member.announcer_subscriptions.create!(announcer: @retired)

    migrate_up

    assert_equal [@slack, @sign, @retired].map(&:id).sort, member.reload.announcer_ids.sort
  end

  test 'leaves members who chose an announcer, and members with announcements off, alone' do
    chose = users(:one)
    chose.update!(announce_arrivals: true)
    chose.announcer_subscriptions.create!(announcer: @sign)
    off = users(:two)
    off.update!(announce_arrivals: false)

    migrate_up

    assert_equal [@sign], chose.reload.announcers.to_a
    assert_empty off.reload.announcers
  end
end
