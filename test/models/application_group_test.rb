require 'test_helper'

class ApplicationGroupTest < ActiveSupport::TestCase
  setup do
    @group = application_groups(:sample_group)
  end

  test 'valid with required attributes' do
    assert @group.valid?
  end

  test 'requires name' do
    @group.name = nil
    assert_not @group.valid?
  end

  test 'requires authentik_name' do
    @group.authentik_name = nil
    assert_not @group.valid?
  end

  test 'requires member_source' do
    @group.member_source = nil
    assert_not @group.valid?
  end

  test 'validates member_source inclusion' do
    @group.member_source = 'invalid'
    assert_not @group.valid?
    assert_includes @group.errors[:member_source], 'is not included in the list'
  end

  test 'requires training_topic for can_train' do
    @group.member_source = 'can_train'
    @group.training_topic_id = nil
    assert_not @group.valid?
    assert_includes @group.errors[:training_topic_id], "can't be blank"
  end

  test 'requires training_topic for trained_in' do
    @group.member_source = 'trained_in'
    @group.training_topic_id = nil
    assert_not @group.valid?
  end

  test 'requires sync_with_group_id for sync_group' do
    @group.member_source = 'sync_group'
    @group.sync_with_group_id = nil
    assert_not @group.valid?
    assert_includes @group.errors[:sync_with_group_id], "can't be blank"
  end

  test 'uses_default_group? returns false for manual' do
    @group.member_source = 'manual'
    assert_not @group.uses_default_group?
  end

  test 'uses_default_group? returns true for non-manual sources' do
    %w[active_members admin_members unbanned_members all_members sync_group can_train trained_in].each do |source|
      @group.member_source = source
      assert @group.uses_default_group?, "Expected uses_default_group? to be true for #{source}"
    end
  end

  test 'member source predicate methods' do
    ApplicationGroup::MEMBER_SOURCES.each do |source|
      @group.member_source = source
      assert @group.send(:"#{source}?"), "Expected #{source}? to be true"
      (ApplicationGroup::MEMBER_SOURCES - [source]).each do |other|
        assert_not @group.send(:"#{other}?"), "Expected #{other}? to be false when source is #{source}"
      end
    end
  end

  test 'effective_members returns active users for active_members' do
    @group.member_source = 'active_members'
    assert_equal User.active.count, @group.effective_members.count
  end

  test 'effective_members returns non-banned users for unbanned_members' do
    @group.member_source = 'unbanned_members'
    expected = User.non_service_accounts.where.not(membership_state: 'banned_member').count
    assert_equal expected, @group.effective_members.count
  end

  test 'effective_members returns all non-service users for all_members' do
    @group.member_source = 'all_members'
    assert_equal User.non_service_accounts.count, @group.effective_members.count
  end

  test 'effective_members returns HABTM users for manual' do
    @group.member_source = 'manual'
    assert_equal @group.users.count, @group.effective_members.count
  end

  test 'policy_name uses naming convention' do
    @group.authentik_name = 'ctrlh:app:wiki:editors'
    assert_equal 'mm-group-membership:ctrlh:app:wiki:editors', @group.policy_name
  end

  test 'policy_expression checks group membership' do
    @group.authentik_name = 'ctrlh:app:wiki:editors'
    expected = 'return ak_is_group_member(request.user, name="ctrlh:app:wiki:editors")'
    assert_equal expected, @group.policy_expression
  end

  test 'clear_irrelevant_associations clears training_topic for non-training sources' do
    topic = training_topics(:laser_cutting)
    @group.member_source = 'can_train'
    @group.training_topic = topic
    @group.save!

    @group.member_source = 'manual'
    @group.save!
    assert_nil @group.training_topic_id
  end

  test 'clear_irrelevant_associations clears sync_with_group for non-sync sources' do
    other = application_groups(:sample_group)
    group = ApplicationGroup.create!(
      application: @group.application,
      name: 'Temp Sync',
      authentik_name: 'test:sync-temp',
      member_source: 'sync_group',
      sync_with_group: other
    )
    group.member_source = 'manual'
    group.save!
    assert_nil group.sync_with_group_id
  end
end
