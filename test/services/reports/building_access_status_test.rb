require 'test_helper'

module Reports
  class BuildingAccessStatusTest < ActiveSupport::TestCase
    setup do
      @topic = training_topics(:building_access)
      MembershipSetting.instance.update!(building_access_training_topic: @topic)
    end

    test 'reports a member holding a key and the training behind it' do
      user = member
      trained_at = Time.zone.local(2024, 3, 15, 14, 30)
      Rfid.create!(user: user, rfid: "BA#{SecureRandom.hex(3)}")
      Training.create!(trainee: user, training_topic: @topic, trained_at: trained_at)

      status = BuildingAccessStatus.for([user]).fetch(user.id)

      assert_predicate status, :key?
      assert_predicate status, :trained?
      assert_equal trained_at, status.trained_at
    end

    # The disagreement is the point: a fob nobody trained for is a process failure.
    test 'reports a key with no training behind it' do
      user = member
      Rfid.create!(user: user, rfid: "BA#{SecureRandom.hex(3)}")

      status = BuildingAccessStatus.for([user]).fetch(user.id)

      assert_predicate status, :key?
      assert_not_predicate status, :trained?
    end

    test 'reports training with no key issued' do
      user = member
      trained_at = 10.days.ago.change(usec: 0)
      Training.create!(trainee: user, training_topic: @topic, trained_at: trained_at)

      status = BuildingAccessStatus.for([user]).fetch(user.id)

      assert_not_predicate status, :key?
      assert_predicate status, :trained?
      assert_equal trained_at, status.trained_at
    end

    test 'uses the most recent building access training date' do
      user = member
      older = 2.years.ago.change(usec: 0)
      newer = 1.month.ago.change(usec: 0)
      Training.create!(trainee: user, training_topic: @topic, trained_at: older)
      Training.create!(trainee: user, training_topic: @topic, trained_at: newer)

      assert_equal newer, BuildingAccessStatus.for([user]).fetch(user.id).trained_at
    end

    test 'a member with neither has no building access' do
      user = member

      status = BuildingAccessStatus.for([user]).fetch(user.id)

      assert_not_predicate status, :any?
      assert_nil status.trained_at
    end

    test 'training on some other topic is not building access' do
      user = member
      Training.create!(trainee: user, training_topic: training_topics(:electronics), trained_at: Time.current)

      assert_not_predicate BuildingAccessStatus.for([user]).fetch(user.id), :trained?
    end

    test 'a page of members costs the same two queries as one' do
      users = Array.new(3) { member }
      users.each { |user| Rfid.create!(user: user, rfid: "BA#{SecureRandom.hex(3)}") }

      assert_equal users.map(&:id).sort, BuildingAccessStatus.for(users).keys.sort
    end

    test 'nothing is trained when no topic is configured or matchable' do
      TrainingTopic.where(id: @topic.id).update_all(name: 'Soldering')
      MembershipSetting.instance.update!(building_access_training_topic: nil)
      user = member
      Training.create!(trainee: user, training_topic: @topic, trained_at: Time.current)

      assert_not_predicate BuildingAccessStatus.for([user]).fetch(user.id), :trained?
    end

    private

    def member
      User.create!(authentik_id: "ba-#{SecureRandom.hex(4)}", full_name: 'Building Access Subject',
                   payment_type: 'unknown', membership_state: 'current_member')
    end
  end
end
