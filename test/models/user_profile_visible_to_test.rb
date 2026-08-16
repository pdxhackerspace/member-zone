require 'test_helper'

# The primitive behind every member listing: who a viewer who cannot read any profile is
# allowed to be shown.
class UserProfileVisibleToTest < ActiveSupport::TestCase
  test 'includes members who opted into sharing' do
    visible = User.profile_visible_to(users(:one))

    assert_includes visible, users(:public_profile_user)
    assert_includes visible, users(:two)
  end

  test 'excludes members who kept their profile private' do
    assert_not_includes User.profile_visible_to(users(:one)), users(:private_profile_user)
  end

  test 'includes the viewer even when their own profile is private' do
    viewer = users(:private_profile_user)

    assert_includes User.profile_visible_to(viewer), viewer
  end

  test 'excludes every private profile when there is no viewer' do
    visible = User.profile_visible_to(nil)

    assert_not_includes visible, users(:private_profile_user)
    assert_includes visible, users(:one)
  end

  test 'composes with a joined relation without widening it' do
    topic = training_topics(:laser_cutting)
    Training.create!(trainee: users(:private_profile_user), training_topic: topic, trained_at: 1.week.ago)
    Training.create!(trainee: users(:one), training_topic: topic, trained_at: 1.week.ago)

    trained = User.joins(:trainings_as_trainee)
                  .where(trainings: { training_topic_id: topic.id })
                  .profile_visible_to(users(:two))
                  .distinct

    assert_includes trained, users(:one)
    assert_not_includes trained, users(:private_profile_user)
  end

  test 'narrows a relation that was already built with an or' do
    scope = User.where(username: 'privateuser').or(User.where(username: 'publicuser'))

    visible = scope.profile_visible_to(users(:one))

    assert_equal [users(:public_profile_user)], visible.to_a
  end
end
