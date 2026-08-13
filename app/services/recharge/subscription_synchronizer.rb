# Periodically polls the Recharge API for subscription status changes.
# Acts as a safety net to catch events that may have been missed by webhooks
# (e.g., due to downtime or network issues).
#
# Detects new subscriptions (ACTIVE) and cancellations (CANCELLED),
# updating user membership_status and creating highlighted journal entries
# mirroring the behavior of Recharge::WebhookHandler.
module Recharge
  class SubscriptionSynchronizer
    DEFAULT_LOOKBACK = 7.days

    # lookback:      how far back to fetch subscription changes (default 7 days)
    # history_only:  when true, only creates PaymentEvents — does not touch
    #                membership_status or create journal entries. Useful for
    #                backfilling historical subscription lifecycle events.
    def initialize(client: Client.new, logger: Rails.logger, lookback: DEFAULT_LOOKBACK, history_only: false)
      @client = client
      @logger = logger
      @lookback = lookback
      @history_only = history_only
    end

    def call
      raise ArgumentError, 'Recharge integration disabled' unless RechargeConfig.enabled?

      subscriptions = @client.subscriptions(start_time: @lookback.ago)
      @logger.info("[Recharge::SubscriptionSynchronizer] Fetched #{subscriptions.size} recently updated subscriptions")

      # Defaults to zero so a status SubscriptionCancellation adds later still counts
      # instead of blowing up the whole sync run.
      stats = Hash.new(0).merge(created: 0, cancelled: 0, skipped: 0)

      subscriptions.each do |sub|
        result = process_subscription(sub)
        stats[result] += 1
      end

      log_summary(stats)
      stats
    end

    private

    def process_subscription(sub)
      case sub[:status]&.upcase
      when 'ACTIVE'
        handle_active(sub)
      when 'CANCELLED'
        handle_cancelled(sub)
      when 'PAUSED'
        handle_paused(sub)
      else
        :skipped
      end
    end

    def handle_active(sub)
      user = find_user(sub)
      return :skipped unless user

      if @history_only
        created = create_payment_event(user, sub, 'subscription_started')
        link_customer_id(user, sub)
        if created
          @logger.info("[Recharge::SubscriptionSynchronizer] [history] subscription_started for #{user.display_name}")
        end
        return created ? :created : :skipped
      end

      return :skipped unless user.cancelled?

      old_state = user.membership_state
      user.record_payment!
      link_customer_id(user, sub)
      create_journal_entry(user, 'subscription_created', sub, old_state, user.membership_state)
      create_payment_event(user, sub, 'subscription_started')

      @logger.info("[Recharge::SubscriptionSynchronizer] Re-activated #{user.display_name} " \
                   "(#{old_state} -> #{user.membership_state})")
      :created
    end

    def handle_cancelled(sub)
      user = find_user(sub)
      return :skipped unless user

      if @history_only
        created = create_payment_event(user, sub, 'subscription_cancelled')
        if created
          @logger.info("[Recharge::SubscriptionSynchronizer] [history] subscription_cancelled for #{user.display_name}")
        end
        return created ? :cancelled : :skipped
      end

      SubscriptionCancellation.call(user: user, subscription: sub, source: 'subscription_sync', logger: @logger)
    end

    def handle_paused(sub)
      user = find_user(sub)
      return :skipped unless user

      create_payment_event(user, sub, 'subscription_paused')

      @logger.info("[Recharge::SubscriptionSynchronizer] Paused subscription for #{user.display_name}")
      :skipped
    end

    def find_user(sub)
      user = User.find_by(recharge_customer_id: sub[:customer_id]) if sub[:customer_id].present?
      user || find_user_by_email(sub[:email])
    end

    def find_user_by_email(email)
      normalized = email.to_s.strip.downcase
      return if normalized.blank?

      User.by_any_email(normalized).first
    end

    def link_customer_id(user, sub)
      return if sub[:customer_id].blank?
      return if user.recharge_customer_id == sub[:customer_id]

      user.update!(recharge_customer_id: sub[:customer_id])
    end

    def create_journal_entry(user, action, sub, old_status, new_status)
      Journal.create!(
        user: user,
        action: action,
        changes_json: {
          action => {
            'source' => 'subscription_sync',
            'recharge_subscription_id' => sub[:recharge_subscription_id],
            'recharge_customer_id' => sub[:customer_id],
            'email' => sub[:email],
            'product_title' => sub[:product_title],
            'price' => sub[:price],
            'previous_membership_status' => old_status,
            'new_membership_status' => new_status,
            'cancellation_reason' => sub[:cancellation_reason],
            'cancelled_at' => sub[:cancelled_at]&.iso8601
          }.compact
        },
        changed_at: Time.current,
        highlight: true
      )
    end

    def create_payment_event(user, sub, event_type)
      external_id = "recharge-sub-#{sub[:recharge_subscription_id]}-#{event_type}"
      return false if PaymentEvent.find_duplicate(source: 'recharge', external_id: external_id, event_type: event_type)

      occurred_at = case event_type
                    when 'subscription_started' then sub[:created_at]
                    when 'subscription_cancelled' then sub[:cancelled_at]
                    end || sub[:updated_at] || Time.current

      PaymentEvent.create!(
        user: user,
        event_type: event_type,
        source: 'recharge',
        amount: sub[:price],
        currency: 'USD',
        occurred_at: occurred_at,
        external_id: external_id,
        details: "Recharge #{event_type.humanize.downcase}: #{sub[:product_title]}"
      )
      true
    rescue ActiveRecord::RecordInvalid => e
      @logger.error("[Recharge::SubscriptionSynchronizer] Failed to create payment event: #{e.message}")
      false
    end

    def log_summary(stats)
      @logger.info(
        '[Recharge::SubscriptionSynchronizer] Done: ' \
        "#{stats[:created]} activated, #{stats[:cancelled]} cancelled, #{stats[:skipped]} skipped"
      )
    end
  end
end
