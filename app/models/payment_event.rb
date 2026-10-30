class PaymentEvent < ApplicationRecord
  EVENT_TYPES = %w[payment subscription_started subscription_cancelled subscription_paused subscription_resumed].freeze
  SOURCES = %w[paypal recharge kofi cash manual].freeze

  belongs_to :user, optional: true
  belongs_to :paypal_payment, optional: true
  belongs_to :recharge_payment, optional: true
  belongs_to :kofi_payment, optional: true
  belongs_to :cash_payment, optional: true

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :occurred_at, presence: true

  scope :ordered, -> { order(occurred_at: :desc, created_at: :desc) }
  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :payments, -> { where(event_type: 'payment') }
  scope :subscriptions, lambda {
    where(event_type: %w[subscription_started subscription_cancelled subscription_paused subscription_resumed])
  }
  scope :by_type, ->(type) { where(event_type: type) }
  scope :by_source, ->(source) { where(source: source) }

  def payment?
    event_type == 'payment'
  end

  def subscription_event?
    event_type.start_with?('subscription_')
  end

  def linked_payment
    paypal_payment || recharge_payment || kofi_payment || cash_payment
  end

  def identifier
    external_id.presence || "EVT-#{id}"
  end

  def processed_time
    occurred_at
  end

  def amount_with_currency
    return nil if amount.blank?

    "#{format('%.2f', amount)} #{currency}"
  end

  def self.find_duplicate(source:, external_id:, event_type:)
    return nil if external_id.blank?

    where(source: source, external_id: external_id, event_type: event_type).first
  end

  # One row per source and external id. A later cancellation or reactivation of the same
  # subscription moves that row forward; a re-delivery of an older notice does not.
  # Returns the existing row, or nil when the caller should create it.
  def self.keep_latest!(occurred_at:, source:, external_id:, event_type:)
    existing = find_duplicate(source: source, external_id: external_id, event_type: event_type)
    return if existing.blank?

    existing.update!(occurred_at: occurred_at) if occurred_at.present? && occurred_at > existing.occurred_at
    existing
  end
end
