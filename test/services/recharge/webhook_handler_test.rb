require 'test_helper'

module Recharge
  class WebhookHandlerTest < ActiveSupport::TestCase
    test 'a new subscription brings back a cancelled member still covered' do
      user = cancelled_member('webhook-covered', dues_due_at: 20.days.from_now)

      handle('subscription/created', user, id: 501)

      assert_equal 'current_member', user.reload.membership_state
      assert_not_predicate user, :cancellation_recorded?
    end

    # The first charge on the new subscription brings them back; the subscription is on file.
    test 'a new subscription does not bring back a member who already went inactive' do
      user = cancelled_member('webhook-lapsed', dues_due_at: 10.days.ago)
      user.update_columns(membership_state: 'inactive_member', membership_state_entered_at: 10.days.ago)

      handle('subscription/created', user, id: 502)

      user.reload
      assert_equal 'inactive_member', user.membership_state
      assert user.payment_events.exists?(event_type: 'subscription_started')
      assert_not_predicate user, :cancellation_on_file?
    end

    private

    def cancelled_member(authentik_id, dues_due_at:)
      user = User.create!(authentik_id: authentik_id, full_name: authentik_id.titleize,
                          email: "#{authentik_id}@example.com", payment_type: 'recharge',
                          membership_state: 'current_member', dues_due_at: dues_due_at)
      user.update_columns(membership_state: 'cancelled_member', membership_cancelled_at: 40.days.ago,
                          membership_state_entered_at: 40.days.ago)
      user.reload
    end

    def handle(topic, user, id:)
      payload = { 'subscription' => { 'id' => id, 'email' => user.email, 'price' => '40.00',
                                      'product_title' => 'Membership' } }
      WebhookHandler.new(topic: topic, payload: payload).call
    end
  end
end
