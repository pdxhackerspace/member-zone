require 'test_helper'

class TrainingTopicRosterTest < ActiveSupport::TestCase
  setup do
    @area = TrainingTopic.create!(name: 'Steward Woodshop', offered_to_members: true)
    @saw = TrainingTopic.create!(name: 'Table saw', parent: @area, offered_to_members: true)
    @bit = TrainingTopic.create!(name: 'Saw blade change', parent: @saw, offered_to_members: true)
    @steward = users(:one)
    @member = users(:three)
    @trained = users(:two)
    @private = users(:private_profile_user)
    train(@steward, @area)
    train(@trained, @saw)
    train(@private, @saw)
    train(@trained, @bit)
  end

  test 'a member sees and contacts nobody until the topic opts in' do
    roster = roster_for(@saw, @member)

    assert_not roster.list_visible?
    assert_not roster.contactable?
    assert_empty roster.members
    assert_empty roster.recipients
  end

  test 'opting in lists active members and links only shared profiles' do
    @saw.update!(trained_members_visible: true, trained_members_contactable: true)
    roster = roster_for(@saw, @member)

    assert_equal [@private.id, @trained.id].sort, roster.members.map(&:id).sort
    assert roster.profile_linked?(@trained)
    assert_not roster.profile_linked?(@private)
    assert_equal [@private.id, @trained.id].sort, roster.recipients.map(&:id).sort
  end

  test 'a member trained in the parent sees and can contact a direct subtopic' do
    roster = roster_for(@saw, @steward)

    assert roster.list_visible?
    assert roster.contactable?
    assert_includes roster.members, @private
    assert_not roster.profile_linked?(@private)
  end

  test 'holding a topic does not reach a grandchild' do
    roster = roster_for(@bit, @steward)

    assert_not roster.list_visible?
    assert_not roster.contactable?
  end

  test 'an admin always sees the list and always gets a profile link' do
    admin = users(:cash_payer)
    admin.update!(is_admin: true)
    roster = roster_for(@saw, admin)

    assert roster.list_visible?
    assert roster.contactable?
    assert roster.profile_linked?(@private)
  end

  test 'members.view_profile links a private profile without revealing a hidden list' do
    grant_privileges(@member, :'members.view_profile')
    roster = roster_for(@saw, @member)

    assert_not roster.list_visible?
    assert roster.profile_linked?(@private)
  end

  test 'other members do not see inactive trained members' do
    @private.update!(membership_state: 'inactive_member')
    @saw.update!(trained_members_visible: true)

    assert_not_includes roster_for(@saw, @member).members, @private
    assert_includes roster_for(@saw, @steward).members, @private
  end

  test 'recipients leave out the viewer and the sender' do
    @saw.update!(trained_members_contactable: true)
    train(@member, @saw)
    train(@steward, @saw)
    roster = roster_for(@saw, @member)

    assert_not_includes roster.recipients(except: @steward), @member
    assert_not_includes roster.recipients(except: @steward), @steward
    assert_includes roster.recipients(except: @steward), @trained
  end

  private

  def roster_for(topic, viewer)
    TrainingTopicRoster.new(topic: topic, viewer: viewer)
  end

  def train(user, topic)
    Training.create!(trainee: user, training_topic: topic, trained_at: Time.current)
  end
end
