class MembershipSetting < ApplicationRecord
  validates :payment_grace_period_days, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :reactivation_grace_period_months, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :invitation_expiry_hours, presence: true, numericality: { greater_than: 0 }
  validates :login_link_expiry_hours, presence: true, numericality: { greater_than: 0 }
  validates :admin_login_link_expiry_minutes, presence: true, numericality: { greater_than: 0 }
  validates :application_verification_expiry_hours, presence: true, numericality: { greater_than: 0 }
  validates :manual_payment_due_soon_days, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :application_review_time_cap_days, presence: true, numericality: { greater_than: 0 }
  validates :slack_signup_reminder_initial_delay_days, presence: true, numericality: { greater_than: 0 }
  validates :slack_signup_reminder_repeat_delay_days, presence: true, numericality: { greater_than: 0 }
  validates :slack_signup_reminder_max_account_age_months, presence: true, numericality: { greater_than: 0 }
  validates :application_link_reminder_delay_days, presence: true, numericality: { greater_than: 0 }
  validates :application_link_reminder_max_count, presence: true, numericality: { greater_than: 0 }
  validates :new_member_grace_period_days, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :new_member_expiry_days, presence: true, numericality: { greater_than: 0 }
  validates :overdue_grace_period_days, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :payment_overdue_reminder_repeat_days, presence: true, numericality: { greater_than: 0 }
  validates :orientation_reminder_repeat_days, presence: true, numericality: { greater_than: 0 }
  validates :parking_notice_reminder_days_before_expiration, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :parking_notice_expired_reminder_repeat_days, presence: true, numericality: { greater_than: 0 }
  validates :parking_notice_final_reminder_days_after_expiration, presence: true, numericality: { greater_than: 0 }
  validates :planless_payment_window_days, presence: true, numericality: { greater_than: 0 }
  validates :payment_currency_buffer_days, presence: true, numericality: { greater_than_or_equal_to: 0 }

  belongs_to :building_access_training_topic, class_name: 'TrainingTopic', optional: true

  # Singleton pattern - only one row should exist
  def self.instance
    first_or_create!(
      payment_grace_period_days: 14,
      reactivation_grace_period_months: 12,
      invitation_expiry_hours: 72,
      login_link_expiry_hours: 180,
      admin_login_link_expiry_minutes: 15,
      application_verification_expiry_hours: 24,
      manual_payment_due_soon_days: 7,
      application_review_time_cap_days: 15,
      slack_signup_reminder_initial_delay_days: 7,
      slack_signup_reminder_repeat_delay_days: 14,
      slack_signup_reminder_max_account_age_months: 6,
      application_link_reminder_delay_days: 3,
      application_link_reminder_max_count: 3,
      new_member_grace_period_days: 14,
      new_member_expiry_days: 90,
      overdue_grace_period_days: 30,
      payment_overdue_reminder_repeat_days: 7,
      orientation_reminder_repeat_days: 14,
      parking_notice_reminder_days_before_expiration: 3,
      parking_notice_expired_reminder_repeat_days: 7,
      parking_notice_final_reminder_days_after_expiration: 14,
      planless_payment_window_days: 32,
      payment_currency_buffer_days: 2
    )
  end

  # Convenience methods for accessing settings
  def self.payment_grace_period_days
    instance.payment_grace_period_days
  end

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

  def self.slack_signup_reminder_initial_delay_days
    instance.slack_signup_reminder_initial_delay_days
  end

  def self.slack_signup_reminder_repeat_delay_days
    instance.slack_signup_reminder_repeat_delay_days
  end

  def self.slack_signup_reminder_max_account_age_months
    instance.slack_signup_reminder_max_account_age_months
  end

  def self.application_link_reminder_delay_days
    instance.application_link_reminder_delay_days
  end

  def self.application_link_reminder_max_count
    instance.application_link_reminder_max_count
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

  def self.payment_overdue_reminder_repeat_days
    instance.payment_overdue_reminder_repeat_days
  end

  # How long after approval an un-oriented member is first reminded, and how long between
  # reminders after that.
  def self.orientation_reminder_repeat_days
    instance.orientation_reminder_repeat_days
  end

  def self.parking_notice_reminder_days_before_expiration
    instance.parking_notice_reminder_days_before_expiration
  end

  def self.parking_notice_expired_reminder_repeat_days
    instance.parking_notice_expired_reminder_repeat_days
  end

  def self.parking_notice_final_reminder_days_after_expiration
    instance.parking_notice_final_reminder_days_after_expiration
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
