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

      return :skipped if user.latest_cancellation_at.blank?

      old_state = user.membership_state
      event_type = return_event_type(user, sub)
      occurred_at = return_occurred_at(sub, event_type)
      return :skipped if occurred_at.blank?

      create_payment_event(user, sub, event_type)
      return :skipped unless user.record_subscription_return!(occurred_at)

      link_customer_id(user, sub)
      create_journal_entry(user, 'subscription_created', sub, old_state, user.membership_state)

      @logger.info("[Recharge::SubscriptionSynchronizer] Re-activated #{user.display_name} " \
                   "(#{old_state} -> #{user.membership_state})")
      :created
    end

    # A new subscription starts at created_at. Reactivating one that was already cancelled
    # keeps that original start, so the return is when Recharge last updated it — the same
    # moment the activation webhook would have reported. An active subscription that was
    # never cancelled is not a return, however recently it was edited.
    def return_event_type(user, sub)
      resumed_subscription?(user, sub) ? 'subscription_resumed' : 'subscription_started'
    end

    def return_occurred_at(sub, event_type)
      event_type == 'subscription_resumed' ? sub[:updated_at] : (sub[:created_at] || sub[:updated_at])
    end

    # The cancel and return rows are one per subscription, so their stored times are the
    # first cycle. A later reactivation is the subscription's own updated_at, once that is
    # after the cancellation the member is on now.
    def resumed_subscription?(user, sub)
      id = sub[:recharge_subscription_id]
      updated_at = sub[:updated_at]
      return false if id.blank? || updated_at.blank?
      return false if subscription_event_at(user, id, 'subscription_cancelled').blank?

      cancellation = user.latest_cancellation_at
      return false if cancellation.blank? || updated_at <= cancellation

      returned_at = latest_return_at(user, id)
      returned_at.blank? || returned_at < updated_at
    end

    def latest_return_at(user, id)
      %w[subscription_started subscription_resumed].filter_map do |type|
        subscription_event_at(user, id, type)
      end.max
    end

    def subscription_event_at(user, id, event_type)
      user.payment_events.where(source: 'recharge', external_id: "recharge-sub-#{id}-#{event_type}")
          .maximum(:occurred_at)
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
      occurred_at = event_occurred_at(sub, event_type)
      return false if PaymentEvent.keep_latest!(occurred_at: occurred_at, source: 'recharge', external_id: external_id,
                                                event_type: event_type)

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

    def event_occurred_at(sub, event_type)
      case event_type
      when 'subscription_started' then sub[:created_at]
      when 'subscription_cancelled' then sub[:cancelled_at]
      end || sub[:updated_at] || Time.current
    end

    def log_summary(stats)
      @logger.info(
        '[Recharge::SubscriptionSynchronizer] Done: ' \
        "#{stats[:created]} activated, #{stats[:cancelled]} cancelled, #{stats[:skipped]} skipped"
      )
    end
  end
end
