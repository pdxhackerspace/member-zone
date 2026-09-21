# Timing that belongs to the membership itself: how long states last, how long tokens stay
# valid, what counts as a current payment.
#
# Reminder cadence is deliberately not here. How long after an event a reminder goes out, how
# often it repeats, and how many go out in total live on the reminder's own ReminderSetting row
# — see Reminders::Schedule.
class MembershipSetting < ApplicationRecord
  validates :reactivation_grace_period_months, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :invitation_expiry_hours, presence: true, numericality: { greater_than: 0 }
  validates :login_link_expiry_hours, presence: true, numericality: { greater_than: 0 }
  validates :admin_login_link_expiry_minutes, presence: true, numericality: { greater_than: 0 }
  validates :application_verification_expiry_hours, presence: true, numericality: { greater_than: 0 }
  validates :manual_payment_due_soon_days, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :application_review_time_cap_days, presence: true, numericality: { greater_than: 0 }
  validates :slack_signup_reminder_max_account_age_months, presence: true, numericality: { greater_than: 0 }
  validates :new_member_grace_period_days, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :new_member_expiry_days, presence: true, numericality: { greater_than: 0 }
  validates :overdue_grace_period_days, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :planless_payment_window_days, presence: true, numericality: { greater_than: 0 }
  validates :payment_currency_buffer_days, presence: true, numericality: { greater_than_or_equal_to: 0 }

  belongs_to :building_access_training_topic, class_name: 'TrainingTopic', optional: true

  # What the singleton row starts with when the table is empty. Mirrors the column
  # defaults, which is what an existing row gets when a new setting is added.
  DEFAULTS = {
    reactivation_grace_period_months: 12,
    invitation_expiry_hours: 72,
    login_link_expiry_hours: 180,
    admin_login_link_expiry_minutes: 15,
    application_verification_expiry_hours: 24,
    manual_payment_due_soon_days: 7,
    application_review_time_cap_days: 15,
    slack_signup_reminder_max_account_age_months: 6,
    new_member_grace_period_days: 14,
    new_member_expiry_days: 90,
    overdue_grace_period_days: 30,
    planless_payment_window_days: 32,
    payment_currency_buffer_days: 2
  }.freeze

  # Singleton pattern - only one row should exist
  def self.instance
    first_or_create!(DEFAULTS)
  end

  # Convenience methods for accessing settings
  def self.reactivation_grace_period_months
    instance.reactivation_grace_period_months
  end

  def self.invitation_expiry_hours
    instance.invitation_expiry_hours
  end

  def self.login_link_expiry_hours
    instance.login_link_expiry_hours
  end

  def self.admin_login_link_expiry_minutes
    instance.admin_login_link_expiry_minutes
  end

  def self.application_verification_expiry_hours
    instance.application_verification_expiry_hours
  end

  def self.manual_payment_due_soon_days
    instance.manual_payment_due_soon_days
  end

  def self.application_review_time_cap_days
    instance.application_review_time_cap_days
  end

  def self.use_builtin_membership_application?
    instance.use_builtin_membership_application?
  end

  # Not a cadence: however many reminders are left in the sequence, somebody who joined years
  # ago and never wanted Slack is not going to be persuaded now. Also filters the report of
  # members without Slack.
  def self.slack_signup_reminder_max_account_age_months
    instance.slack_signup_reminder_max_account_age_months
  end

  # How long a newly trained member stays active before their first payment is expected.
  def self.new_member_grace_period_days
    instance.new_member_grace_period_days
  end

  # Cap on how long someone approved but never trained stays active.
  def self.new_member_expiry_days
    instance.new_member_expiry_days
  end

  # How long an overdue member keeps access before falling inactive.
  def self.overdue_grace_period_days
    instance.overdue_grace_period_days
  end

  # How long a payment counts as current when the member has no membership plan assigned.
  def self.planless_payment_window_days
    instance.planless_payment_window_days
  end

  # Extra days added to a plan's billing cycle when deciding whether a payment is still current.
  def self.payment_currency_buffer_days
    instance.payment_currency_buffer_days
  end

  # The topic whose training moves a new member into their pre-payment grace period.
  def self.building_access_training_topic
    instance.building_access_training_topic
  end

  def self.building_access_training_topic_id
    instance.building_access_training_topic_id
  end
end
