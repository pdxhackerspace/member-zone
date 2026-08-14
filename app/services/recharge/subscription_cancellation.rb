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
      return declined(old_state) unless @user.record_cancellation!(cancelled_at: cancelled_at)

      create_journal_entry(old_state) if event_is_new
      @logger.info("[Recharge::SubscriptionCancellation] #{@source}: #{@user.display_name} " \
                   "(#{old_state} -> #{@user.membership_state})")
      event_is_new ? :cancelled : :skipped
    end

    private

    # Where record_cancellation! will not follow, which is two different situations wearing
    # the same false. A member who lapsed before anyone processed the notice is already
    # where it would have put them and needs only the date — without it they look exactly
    # like someone who quietly stopped paying, and the lapse email chases them for a
    # decision they told us about. A ban, a death, a sponsorship, or a guest pass was
    # decided by a person and outranks the notice entirely.
    #
    # Membership::CancellationReconciler draws the line in the same place for the backlog;
    # it reads from the same list so a webhook and a later reconcile cannot disagree.
    def declined(old_state)
      return state_locked(old_state) unless old_state.in?(Membership::CancellationReconciler::NOTE_ONLY_STATES)

      @user.note_cancellation!(cancelled_at: cancelled_at)
      @logger.info("[Recharge::SubscriptionCancellation] #{@source}: #{@user.display_name} " \
                   "cancelled at Recharge; recorded against #{old_state}")
      :noted
    end

    # The payment event still stands — the subscription really did end at Recharge — but the
    # member's standing is not the notice's to change, and no journal entry claims otherwise.
    def state_locked(old_state)
      @logger.info("[Recharge::SubscriptionCancellation] #{@source}: #{@user.display_name} " \
                   "cancelled at Recharge; left in #{old_state}")
      :state_locked
    end

    def subscription_id
      @subscription[:recharge_subscription_id] || @subscription['id']
    end

    # When the member cancelled, not when we got around to reading the notice. The payment
    # event and the stamp on the member both date from it, so a webhook and the reconcile
    # that would have caught the same notice later record the same day.
    def cancelled_at
      subscription_cancelled_at || Time.current
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
        occurred_at: cancelled_at,
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
