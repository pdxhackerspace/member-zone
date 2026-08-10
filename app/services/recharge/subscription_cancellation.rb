module Recharge
  # Records that a Recharge subscription was cancelled: one payment event, one journal
  # entry, and record_cancellation! on the member. WebhookHandler and
  # SubscriptionSynchronizer both delegate here so the deferred-cancellation rule lives
  # in one place.
  class SubscriptionCancellation
    def self.call(user:, subscription:, source:, logger: Rails.logger)
      new(user, subscription, source, logger).call
    end

    def initialize(user, subscription, source, logger)
      @user = user
      @subscription = subscription
      @source = source
      @logger = logger
    end

    def call
      return :already_cancelled if @user.cancelled_member?

      old_state = @user.membership_state
      event_is_new = create_payment_event
      return state_locked(old_state) unless @user.record_cancellation!

      create_journal_entry(old_state) if event_is_new
      @logger.info("[Recharge::SubscriptionCancellation] #{@source}: #{@user.display_name} " \
                   "(#{old_state} -> #{@user.membership_state})")
      event_is_new ? :cancelled : :skipped
    end

    private

    # A ban or a death outranks a cancellation notice. The payment event still stands —
    # the subscription really did end at Recharge — but the member's standing is not the
    # notice's to change, and no journal entry claims otherwise.
    def state_locked(old_state)
      @logger.info("[Recharge::SubscriptionCancellation] #{@source}: #{@user.display_name} " \
                   "cancelled at Recharge; left in #{old_state}")
      :state_locked
    end

    def subscription_id
      @subscription[:recharge_subscription_id] || @subscription['id']
    end

    def create_payment_event
      external_id = "recharge-sub-#{subscription_id}-subscription_cancelled"
      return false if PaymentEvent.find_duplicate(source: 'recharge', external_id: external_id,
                                                  event_type: 'subscription_cancelled')

      PaymentEvent.create!(
        user: @user,
        event_type: 'subscription_cancelled',
        source: 'recharge',
        amount: subscription_amount,
        currency: 'USD',
        occurred_at: subscription_cancelled_at || Time.current,
        external_id: external_id,
        details: "Recharge subscription cancelled: #{subscription_title}"
      )
      true
    rescue ActiveRecord::RecordInvalid => e
      @logger.error("[Recharge::SubscriptionCancellation] Failed to create payment event: #{e.message}")
      false
    end

    def create_journal_entry(old_state)
      Journal.create!(
        user: @user,
        action: 'subscription_cancelled',
        changes_json: {
          'subscription_cancelled' => {
            'source' => @source,
            'recharge_subscription_id' => subscription_id,
            'recharge_customer_id' => subscription_customer_id,
            'email' => subscription_email,
            'product_title' => subscription_title,
            'price' => subscription_amount,
            'previous_membership_state' => old_state,
            'new_membership_state' => @user.membership_state,
            'cancellation_reason' => subscription_cancellation_reason,
            'cancelled_at' => subscription_cancelled_at&.iso8601
          }.compact
        },
        changed_at: Time.current,
        highlight: true
      )
    end

    def subscription_amount
      @subscription[:price] || @subscription['price']
    end

    def subscription_title
      @subscription[:product_title] || @subscription['product_title']
    end

    def subscription_email
      @subscription[:email] || @subscription['email']
    end

    def subscription_customer_id
      @subscription[:customer_id] || @subscription['customer_id']&.to_s
    end

    def subscription_cancellation_reason
      @subscription[:cancellation_reason] || @subscription['cancellation_reason']
    end

    def subscription_cancelled_at
      value = @subscription[:cancelled_at] || @subscription['cancelled_at']
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      Time.zone.parse(value.to_s) if value.present?
    rescue ArgumentError
      nil
    end
  end
end
