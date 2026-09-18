class MailLogEntry < ApplicationRecord
  EVENTS = %w[created edited regenerated approved rejected sent send_failed suppressed].freeze

  # The log stores events, but an admin reading it is asking about the state of outgoing mail —
  # usually "what did not go out". These group the events into the questions worth asking, so
  # finding failures is a click instead of a read of every row.
  STATE_FILTERS = {
    'sent' => %w[sent],
    'failed' => %w[send_failed],
    'suppressed' => %w[suppressed],
    'rejected' => %w[rejected],
    'queued' => %w[created],
    'approved' => %w[approved],
    'edited' => %w[edited regenerated]
  }.freeze

  belongs_to :queued_mail, optional: true
  belongs_to :actor, class_name: 'User', optional: true

  validates :event, presence: true, inclusion: { in: EVENTS }
  validate :queued_mail_or_direct_delivery_fields

  scope :newest_first, -> { order(created_at: :desc) }
  scope :oldest_first, -> { order(created_at: :asc) }
  scope :for_state, ->(state) { where(event: STATE_FILTERS.fetch(state, EVENTS)) }

  # Recipients and subjects are snapshotted onto the entry, but entries written before that column
  # existed only have the queued mail to go on, so both are searched. Neither column is encrypted,
  # unlike +users.email+, so a substring match is possible here.
  scope :matching, lambda { |term|
    pattern = "%#{sanitize_sql_like(term)}%"
    left_joins(:queued_mail).where(
      'mail_log_entries.delivery_to ILIKE :pattern OR mail_log_entries.delivery_subject ILIKE :pattern ' \
      'OR queued_mails.to ILIKE :pattern OR queued_mails.subject ILIKE :pattern',
      pattern: pattern
    )
  }

  # One grouped query behind every chip count, so the filter row costs the same as the page it
  # sits on. Counts follow the search box, because a count that ignored it would be a lie.
  def self.state_filter_counts(search: nil)
    by_event = (search.present? ? matching(search) : all).group('mail_log_entries.event').count
    STATE_FILTERS.transform_values { |events| events.sum { |event| by_event.fetch(event, 0) } }
                 .merge('all' => by_event.values.sum)
  end

  def self.log!(queued_mail, event, actor: nil, details: nil)
    create!(
      **queued_mail_snapshot_attrs(queued_mail),
      event: event,
      actor: actor,
      details: details
    )
  end

  # Logs an immediate Action Mailer delivery (not via +QueuedMail+).
  # rubocop:disable-next Metrics/ParameterLists -- mirrors mail metadata fields
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
