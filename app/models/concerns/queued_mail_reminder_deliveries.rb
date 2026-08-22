module QueuedMailReminderDeliveries
  extend ActiveSupport::Concern

  SLACK_SIGNUP_REMINDER_ACTIONS = %w[slack_signup_reminder slack_signup_nag].freeze

  PARKING_REMINDER_ACTIONS = %w[
    parking_permit_expiring_soon parking_ticket_expiring_soon
    parking_permit_expired parking_ticket_expired
    parking_permit_overdue_reminder parking_ticket_overdue_reminder
    parking_permit_final_reminder parking_ticket_final_reminder
  ].freeze

  def record_reminder_deliveries!(sent_time)
    record_slack_signup_reminder_delivery!(sent_time) if slack_signup_reminder_delivery?
    record_application_link_reminder_delivery!(sent_time) if application_link_reminder_delivery?
    record_orientation_reminder_delivery!(sent_time) if orientation_reminder_delivery?
    record_parking_notice_reminder_delivery!(sent_time) if parking_notice_reminder_delivery?
  end

  private

  def slack_signup_reminder_delivery?
    SLACK_SIGNUP_REMINDER_ACTIONS.include?(mailer_action) && recipient.present?
  end

  def record_slack_signup_reminder_delivery!(sent_time)
    Reminders::NotifySlackSignup.record_delivery!(recipient, at: sent_time)
  rescue StandardError => e
    Rails.logger.error(
      "[QueuedMail] slack_signup_reminder stamp failed queued_mail_id=#{id} user_id=#{recipient&.id} " \
      "#{e.class}: #{e.message}"
    )
    raise
  end

  def orientation_reminder_delivery?
    mailer_action == 'orientation_reminder' && recipient.present?
  end

  def record_orientation_reminder_delivery!(sent_time)
    Reminders::NotifyOrientation.record_delivery!(recipient, at: sent_time)
  rescue StandardError => e
    Rails.logger.error(
      "[QueuedMail] orientation_reminder stamp failed queued_mail_id=#{id} user_id=#{recipient&.id} " \
      "#{e.class}: #{e.message}"
    )
    raise
  end

  def application_link_reminder_delivery?
    mailer_action == 'application_link_reminder'
  end

  def parking_notice_reminder_delivery?
    PARKING_REMINDER_ACTIONS.include?(mailer_action)
  end

  def record_parking_notice_reminder_delivery!(sent_time)
    notice_id = mailer_args.is_a?(Hash) && mailer_args['parking_notice_id']
    notice = ParkingNotice.find_by(id: notice_id) if notice_id.present?
    return unless notice

    phase = parking_reminder_phase_for_action(mailer_action)
    return unless phase

    Reminders::NotifyParkingNotices.record_delivery!(notice, phase, at: sent_time)
  rescue StandardError => e
    Rails.logger.error(
      "[QueuedMail] parking reminder stamp failed queued_mail_id=#{id} notice_id=#{notice_id} " \
      "#{e.class}: #{e.message}"
    )
    raise
  end

  def parking_reminder_phase_for_action(action)
    case action
    when 'parking_permit_expiring_soon', 'parking_ticket_expiring_soon' then :pre_expiration
    when 'parking_permit_expired', 'parking_ticket_expired' then :expiration
    when 'parking_permit_overdue_reminder', 'parking_ticket_overdue_reminder' then :overdue
    when 'parking_permit_final_reminder', 'parking_ticket_final_reminder' then :final
    end
  end

  def record_application_link_reminder_delivery!(sent_time)
    verification_id = mailer_args.is_a?(Hash) && mailer_args['application_verification_id']
    verification = ApplicationVerification.find_by(id: verification_id) if verification_id.present?
    return unless verification

    Reminders::NotifyApplicationLink.record_delivery!(verification, at: sent_time)
  rescue StandardError => e
    Rails.logger.error(
      "[QueuedMail] application_link_reminder stamp failed queued_mail_id=#{id} " \
      "verification_id=#{verification_id} #{e.class}: #{e.message}"
    )
    raise
  end
end
