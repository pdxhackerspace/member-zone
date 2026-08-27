class MailLogEntry < ApplicationRecord
  EVENTS = %w[created edited regenerated approved rejected sent send_failed suppressed].freeze

  belongs_to :queued_mail, optional: true
  belongs_to :actor, class_name: 'User', optional: true

  validates :event, presence: true, inclusion: { in: EVENTS }
  validate :queued_mail_or_direct_delivery_fields

  scope :newest_first, -> { order(created_at: :desc) }
  scope :oldest_first, -> { order(created_at: :asc) }

  def self.log!(queued_mail, event, actor: nil, details: nil)
    create!(
      **queued_mail_snapshot_attrs(queued_mail),
      event: event,
      actor: actor,
      details: details
    )
  end

  # Logs an immediate Action Mailer delivery (not via +QueuedMail+).
  # rubocop:disable Metrics/ParameterLists -- mirrors mail metadata fields
  def self.log_direct_delivery!(to:, subject:, mailer_class:, mailer_action:, details: nil, actor: nil,
                                event: 'sent', body_html: nil, body_text: nil)
    detail = details.presence || [mailer_class, mailer_action].compact.join('#')
    create!(
      queued_mail: nil,
      event: event,
      actor: actor,
      details: detail,
      delivery_to: to,
      delivery_subject: subject,
      delivery_mailer: mailer_class,
      delivery_action: mailer_action,
      delivery_body_html: body_html,
      delivery_body_text: body_text
    )
  end
  # rubocop:enable Metrics/ParameterLists

  def self.log_queued_delivery!(queued_mail)
    create!(
      **queued_mail_snapshot_attrs(queued_mail),
      event: 'sent',
      details: "Delivered to #{queued_mail.to}"
    )
  end

  def self.queued_mail_snapshot_attrs(queued_mail)
    return {} unless queued_mail

    {
      queued_mail: queued_mail,
      delivery_to: queued_mail.to,
      delivery_subject: queued_mail.subject,
      delivery_mailer: 'QueuedMailMailer',
      delivery_action: queued_mail.mailer_action,
      delivery_body_html: queued_mail.body_html,
      delivery_body_text: queued_mail.body_text
    }
  end
  private_class_method :queued_mail_snapshot_attrs

  def self.log_once!(queued_mail, event, actor: nil, details: nil)
    last_entry = queued_mail.mail_log_entries
                            .where(event: event)
                            .order(created_at: :desc)
                            .first

    return if last_entry && last_entry.details == details

    log!(queued_mail, event, actor: actor, details: details)
  end

  def wait_duration
    return nil unless event.in?(%w[approved rejected sent])
    return nil unless queued_mail

    queued_mail.created_at ? (created_at - queued_mail.created_at) : nil
  end

  def wait_duration_in_words
    seconds = wait_duration
    return nil unless seconds

    if seconds < 60
      'less than a minute'
    elsif seconds < 3600
      "#{(seconds / 60).round} minutes"
    elsif seconds < 86_400
      hours = (seconds / 3600).round
      "#{hours} #{'hour'.pluralize(hours)}"
    else
      days = (seconds / 86_400).round
      "#{days} #{'day'.pluralize(days)}"
    end
  end

  def message_to
    delivery_to.presence || queued_mail&.to
  end

  def message_subject
    delivery_subject.presence || queued_mail&.subject
  end

  def message_body_html
    delivery_body_html.presence || queued_mail&.body_html
  end

  def message_body_text
    delivery_body_text.presence || queued_mail&.body_text
  end

  def message_available?
    message_body_html.present? || message_body_text.present?
  end

  private

  def queued_mail_or_direct_delivery_fields
    return if queued_mail.present?
    return if delivery_to.present? && delivery_subject.present?

    errors.add(:base, 'Either queued mail or direct delivery fields (to and subject) must be present')
  end
end
