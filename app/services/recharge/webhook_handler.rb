module Recharge
  # Handles incoming Recharge subscription webhook events.
  # Processes subscription/created and subscription/cancelled topics,
  # updating user membership status and creating highlighted journal entries.
  class WebhookHandler
    SUPPORTED_TOPICS = %w[subscription/created subscription/cancelled subscription/activated subscription/paused].freeze

    def initialize(topic:, payload:)
      @topic = topic
      @payload = payload
      @subscription = payload['subscription'] || {}
    end

    def call
      unless SUPPORTED_TOPICS.include?(@topic)
        Rails.logger.info("[Recharge::WebhookHandler] Ignoring unsupported topic: #{@topic}")
        return { status: 'ignored', reason: "unsupported topic: #{@topic}" }
      end

      case @topic
      when 'subscription/created'
        handle_subscription_created
      when 'subscription/cancelled'
        handle_subscription_cancelled
      when 'subscription/activated'
        handle_subscription_resumed
      when 'subscription/paused'
        handle_subscription_paused
      end
    end

    private

    def handle_subscription_created
      user = find_user
      return user_not_found('subscription/created') unless user

      old_state = user.membership_state
      user.record_payment! if user.cancelled?
      user.update!(recharge_customer_id: customer_id) if link_customer_id?(user)

      details = { 'previous_membership_state' => old_state,
                  'new_membership_state' => user.reload.membership_state }
      create_journal_entry(user: user, action: 'subscription_created', details: details)
      create_payment_event(user, 'subscription_started')
      log_and_respond('subscription/created', user, old_state, user.membership_state)
    end

    # Recording the cancellation is enough: User keeps the member active until their
    # paid-through date and moves them to inactive when it passes.
    def handle_subscription_cancelled
      user = find_user
      return user_not_found('subscription/cancelled') unless user
      return log_and_respond('subscription/cancelled', user, 'cancelled_member', 'cancelled_member') if user.cancelled?

      old_state = user.membership_state
      SubscriptionCancellation.call(user: user, subscription: @subscription, source: 'webhook')
      log_and_respond('subscription/cancelled', user, old_state, user.membership_state)
    end

    def handle_subscription_resumed
      user = find_user
      return user_not_found('subscription/activated') unless user

      old_state = user.membership_state
      user.record_payment! if user.cancelled?
      user.update!(recharge_customer_id: customer_id) if link_customer_id?(user)

      details = { 'previous_membership_state' => old_state,
                  'new_membership_state' => user.reload.membership_state }
      create_journal_entry(user: user, action: 'subscription_resumed', details: details)
      create_payment_event(user, 'subscription_resumed')
      log_and_respond('subscription/activated', user, old_state, user.membership_state)
    end

    def handle_subscription_paused
      user = find_user
      return user_not_found('subscription/paused') unless user

      details = { 'previous_membership_state' => user.membership_state }
      create_journal_entry(user: user, action: 'subscription_paused', details: details)
      create_payment_event(user, 'subscription_paused')
      log_and_respond('subscription/paused', user, user.membership_state, user.membership_state)
    end

    def link_customer_id?(user)
      customer_id.present? && user.recharge_customer_id != customer_id
    end

    def user_not_found(topic)
      Rails.logger.warn("[Recharge::WebhookHandler] #{topic}: no user found for #{identifier_summary}")
      { status: 'skipped', reason: 'user not found' }
    end

    def log_and_respond(topic, user, old_status, new_status)
      Rails.logger.info("[Recharge::WebhookHandler] #{topic}: #{user.display_name} (#{old_status} -> #{new_status})")
      { status: 'processed', user_id: user.id, action: topic.tr('/', '_') }
    end

    def find_user
      if customer_id.present? && User.exists?(recharge_customer_id: customer_id)
        return User.find_by(recharge_customer_id: customer_id)
      end
      return if subscription_email.blank?

      User.by_any_email(subscription_email).first
    end

    def customer_id
      @customer_id ||= @subscription['customer_id']&.to_s
    end

    def subscription_email
      @subscription_email ||= @subscription['email']
    end

    def identifier_summary
      [("customer_id=#{customer_id}" if customer_id.present?),
       ("email=#{subscription_email}" if subscription_email.present?)].compact.join(', ')
    end

    def create_journal_entry(user:, action:, details:)
      Journal.create!(
        user: user,
        action: action,
        changes_json: { action => subscription_summary.merge(details) },
        changed_at: Time.current,
        highlight: true
      )
    end

    def create_payment_event(user, event_type)
      sub_id = @subscription['id']
      external_id = "recharge-sub-#{sub_id}-#{event_type}"
      return if PaymentEvent.find_duplicate(source: 'recharge', external_id: external_id, event_type: event_type)

      PaymentEvent.create!(
        user: user,
        event_type: event_type,
        source: 'recharge',
        amount: @subscription['price'],
        currency: 'USD',
        occurred_at: Time.current,
        external_id: external_id,
        details: "Recharge #{event_type.humanize.downcase}: #{@subscription['product_title']}"
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("[Recharge::WebhookHandler] Failed to create payment event: #{e.message}")
    end

    def subscription_summary
      {
        'recharge_subscription_id' => @subscription['id'],
        'recharge_customer_id' => customer_id,
        'email' => subscription_email,
        'product_title' => @subscription['product_title'],
        'status' => @subscription['status'],
        'price' => @subscription['price']
      }.compact
    end
  end
end
