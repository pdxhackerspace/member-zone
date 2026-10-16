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
  scope :paid_between, ->(from, to) { where(paid_on: from..to) }
  scope :search, lambda { |term|
    pattern = "%#{term.to_s.downcase}%"
    # Member emails are encrypted, so they match only on a whole address, via the digest.
    digest = SensitiveData.email_digest(term)
    joins(:user, :membership_plan).where(
      "LOWER(COALESCE(users.full_name, '')) LIKE :q " \
      "OR LOWER(COALESCE(membership_plans.name, '')) LIKE :q " \
      "OR LOWER(COALESCE(cash_payments.notes, '')) LIKE :q " \
      'OR users.email_lookup_digest = :d',
      q: pattern, d: digest
    )
  }

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
