require 'test_helper'

module Recharge
  class SubscriptionSynchronizerTest < ActiveSupport::TestCase
    SUBSCRIPTION_ID = 'sub-resume-1'.freeze

    test 'a subscription created after the cancellation brings a covered member back' do
      user = cancelled_member('sync-new-sub')
      started_at = 1.day.ago

      sync(subscription(user, created_at: started_at, updated_at: started_at))

      assert_equal 'current_member', user.reload.membership_state
      assert_equal started_at.to_i, return_event(user, 'subscription_started').occurred_at.to_i
    end

    test 'reactivating the cancelled subscription is dated from the reactivation' do
      user = cancelled_member('sync-resume')
      file_cancellation_event(user)
      reactivated_at = 1.hour.ago

      sync(subscription(user, created_at: 1.year.ago, updated_at: reactivated_at))

      user.reload
      assert_equal 'current_member', user.membership_state
      assert_not user.payment_events.exists?(event_type: 'subscription_started',
                                             external_id: "recharge-sub-#{SUBSCRIPTION_ID}-subscription_started")
      assert_equal reactivated_at.to_i, return_event(user, 'subscription_resumed').occurred_at.to_i
    end

    test 'an older active subscription that was never cancelled is not a return' do
      user = cancelled_member('sync-unrelated')

      sync(subscription(user, created_at: 1.year.ago, updated_at: 1.hour.ago))

      user.reload
      assert_equal 'cancelled_member', user.membership_state
      assert_not user.returned_after?(user.membership_cancelled_at)
    end

    # The cancel and resume rows are one per subscription, so a second cycle has to move
    # the resume row forward instead of trusting the time left from the first return.
    test 'a later reactivation of the same subscription is dated from that reactivation' do
      user = cancelled_member('sync-resume-again')
      user.payment_events.create!(event_type: 'subscription_cancelled', source: 'recharge', amount: 40,
                                  currency: 'USD', occurred_at: 30.days.ago,
                                  external_id: "recharge-sub-#{SUBSCRIPTION_ID}-subscription_cancelled")
      user.payment_events.create!(event_type: 'subscription_resumed', source: 'recharge', amount: 40,
                                  currency: 'USD', occurred_at: 20.days.ago,
                                  external_id: "recharge-sub-#{SUBSCRIPTION_ID}-subscription_resumed")
      user.update_columns(membership_cancelled_at: 2.days.ago, membership_state_entered_at: 2.days.ago)
      reactivated_at = 1.hour.ago

      sync(subscription(user, created_at: 1.year.ago, updated_at: reactivated_at))

      user.reload
      assert_equal 'current_member', user.membership_state
      assert_equal 1, user.payment_events.where(event_type: 'subscription_resumed').count
      assert_equal reactivated_at.to_i, return_event(user, 'subscription_resumed').occurred_at.to_i
      assert user.returned_after?(2.days.ago)
    end

    private

    def sync(subscription)
      with_recharge_enabled do
        SubscriptionSynchronizer.new(client: Client.new(subscription)).call
      end
    end

    def with_recharge_enabled
      settings = RechargeConfig.settings
      previous = settings.api_key
      settings.api_key = 'test-key'
      yield
    ensure
      settings.api_key = previous
    end

    def cancelled_member(authentik_id)
      user = User.create!(authentik_id: authentik_id, full_name: authentik_id.titleize,
                          email: "#{authentik_id}@example.com", payment_type: 'recharge',
                          membership_state: 'current_member', dues_due_at: 20.days.from_now,
                          last_payment_date: 5.days.ago.to_date, recharge_customer_id: "cust-#{authentik_id}")
      user.update_columns(membership_state: 'cancelled_member', membership_cancelled_at: 3.days.ago,
                          membership_state_entered_at: 3.days.ago)
      user.reload
    end

    def file_cancellation_event(user)
      user.payment_events.create!(event_type: 'subscription_cancelled', source: 'recharge', amount: 40,
                                  currency: 'USD', occurred_at: user.membership_cancelled_at,
                                  external_id: "recharge-sub-#{SUBSCRIPTION_ID}-subscription_cancelled")
    end

    def subscription(user, created_at:, updated_at:)
      {
        status: 'ACTIVE',
        recharge_subscription_id: SUBSCRIPTION_ID,
        customer_id: user.recharge_customer_id,
        email: user.email,
        product_title: 'Monthly',
        price: 40.0,
        created_at: created_at,
        updated_at: updated_at
      }
    end

    def return_event(user, event_type)
      user.payment_events.find_by!(event_type: event_type, source: 'recharge')
    end

    class Client
      def initialize(subscription)
        @subscription = subscription
      end

      def subscriptions(start_time:)
        start_time ? [@subscription] : []
      end
    end
  end
end
