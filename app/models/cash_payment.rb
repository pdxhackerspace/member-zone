class CashPayment < ApplicationRecord
  belongs_to :user
  belongs_to :membership_plan
  belongs_to :recorded_by, class_name: 'User', optional: true
  has_many :payment_events, dependent: :destroy

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :paid_on, presence: true
  validate :membership_plan_must_be_personal

  scope :ordered, -> { order(paid_on: :desc, created_at: :desc) }
  scope :for_user, ->(user) { where(user_id: user.id) }

  def identifier
    "CASH-#{id}"
  end

  def processed_time
    paid_on&.beginning_of_day
  end

  def amount_with_currency
    return nil if amount.blank?

    "#{format('%.2f', amount)} USD"
  end

  def status
    'completed'
  end

  private

  def membership_plan_must_be_personal
    return if membership_plan.blank?

    errors.add(:membership_plan, 'must be a personal plan') unless membership_plan.personal?
  end
end
