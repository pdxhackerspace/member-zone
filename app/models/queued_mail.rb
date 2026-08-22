class QueuedMail < ApplicationRecord
  include QueuedMailReminderDeliveries
  include QueuedMailApplicationLinkReminders

  STATUSES = %w[pending approved rejected].freeze

  # Stand-in for +MemberMailer.build_template_variables+ when the applicant has no User yet
  ApplicantMailRecipient = Data.define(:display_name, :email, :username)
  ImmediateDelivery = Data.define(:to, :subject, :body_html, :body_text, :email_template)

  belongs_to :email_template, optional: true
  belongs_to :recipient, class_name: 'User', optional: true
  belongs_to :reviewed_by, class_name: 'User', optional: true
  has_many :mail_log_entries, dependent: :destroy

  validates :to, :subject, :body_html, :reason, :mailer_action, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: 'pending') }
  scope :approved, -> { where(status: 'approved') }
  scope :rejected, -> { where(status: 'rejected') }
  scope :unsent, -> { approved.where(sent_at: nil) }
  scope :failed, -> { approved.where(sent_at: nil).where.not(last_error: nil) }
  scope :newest_first, -> { order(created_at: :desc) }

  def self.pending_ban_mail_for?(user)
    exists?(recipient: user, mailer_action: 'membership_banned', status: %w[pending approved], sent_at: nil)
  end

  def pending?  = status == 'pending'
  def approved? = status == 'approved'
  def rejected? = status == 'rejected'

  def sent?
    approved? && sent_at.present?
  end

  def delivery_pending?
    approved? && sent_at.nil? && last_error.nil?
  end

  def delivery_failed?
    approved? && sent_at.nil? && last_error.present?
  end

  def self.enqueue(action, user, to: nil, reason: nil, **extra_args)
    dest = to || user.email
    return nil if dest.blank?

    template = EmailTemplate.find_enabled(action.to_s)
    variables = enqueue_render_variables(action, user, extra_args, template)

    if !MailRecipientGuard.blocked?(user) && template&.send_immediately?
      return deliver_immediately(template, dest, variables)
    end

    record = if template
               create_queued_mail_from_template(
                 template,
                 variables,
                 queued_mail_attrs(dest, reason || action.to_s.humanize, user, action.to_s, extra_args)
               )
             else
               message = dispatch_mailer(action, build_mailer_args(action, user, to, extra_args))
               create_queued_mail_from_message(
                 message,
                 queued_mail_attrs(dest, reason || action.to_s.humanize, user, action.to_s, extra_args)
               )
             end

    MailLogEntry.log!(record, 'created', details: "Queued #{action.to_s.humanize} to #{dest}")
    MailRecipientGuard.block_delivery_to!(record)
    record
  end

  # Queues the applicant-facing rejection email (pending review, then +QueuedMailDeliveryJob+).
  def self.enqueue_application_rejected(membership_application, reason: nil)
    dest = membership_application.user&.email.presence || membership_application.email
    return nil if dest.blank?

    recipient_user = membership_application.user
    template_recipient = recipient_user || applicant_recipient_for(membership_application)
    action = 'application_rejected'
    template = EmailTemplate.find_enabled(action)
    extra_args = { reason: reason.presence }.compact

    variables = MemberMailer.build_template_variables(template_recipient, extra_args)

    return deliver_immediately(template, dest, variables) if template&.send_immediately?

    record = if template
               create_queued_mail_from_template(
                 template,
                 variables,
                 queued_mail_attrs(dest, 'Application rejected', recipient_user, action, extra_args)
               )
             else
               message = MemberMailer.application_rejected(template_recipient, **extra_args)
               create_queued_mail_from_message(
                 message,
                 queued_mail_attrs(dest, 'Application rejected', recipient_user, action, extra_args)
               )
             end

    MailLogEntry.log!(record, 'created', details: "Queued application rejected to #{dest}")
    MailRecipientGuard.block_delivery_to!(record)
    record
  end

  def self.ensure_admin_new_application_application_url!(variables, action, extra_args)
    return unless action.to_s == 'admin_new_application'

    raw = extra_args[:application_url].presence || extra_args['application_url'].presence
    variables[:application_url] = raw.presence ||
                                  "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000').chomp('/')}/membership_applications"
  end

  def self.applicant_recipient_for(application)
    name = application.applicant_display_name
    name = 'Applicant' if name.blank? || name == '—'
    ApplicantMailRecipient.new(
      display_name: name,
      email: application.email,
      username: 'Not set'
    )
  end

  def self.deliver_immediately(template, dest, variables)
    rendered = template.render(variables)
    EmailTemplateMailer.send_rendered(
      to: dest,
      subject: rendered[:subject],
      body_html: rendered[:body_html],
      body_text: rendered[:body_text] || ''
    ).deliver_now

    ImmediateDelivery.new(
      to: dest,
      subject: rendered[:subject],
      body_html: rendered[:body_html],
      body_text: rendered[:body_text] || '',
      email_template: template
    )
  end

  def self.queued_mail_attrs(dest, reason, recipient, action, args)
    {
      to: dest,
      reason: reason,
      recipient: recipient,
      mailer_action: action,
      mailer_args: args
    }
  end

  def self.create_queued_mail_from_template(template, variables, attrs)
    rendered = template.render(variables)
    create!(
      **attrs,
      subject: rendered[:subject],
      body_html: rendered[:body_html],
      body_text: rendered[:body_text] || '',
      email_template: template
    )
  end

  def self.create_queued_mail_from_message(message, attrs)
    msg = message.message
    html_body = msg.multipart? ? msg.html_part&.body&.decoded : msg.body.decoded
    text_body = msg.multipart? ? msg.text_part&.body&.decoded : ''

    create!(
      **attrs,
      subject: msg.subject,
      body_html: html_body || '',
      body_text: text_body || ''
    )
  end

  def approve!(reviewer)
    return false if MailRecipientGuard.block_delivery_to!(self)

    update!(status: 'approved', reviewed_by: reviewer, reviewed_at: Time.current)
    MailLogEntry.log!(self, 'approved', actor: reviewer, details: "Approved for delivery to #{to}")
    QueuedMailDeliveryJob.perform_later(id)
    true
  end

  def reject!(reviewer)
    update!(status: 'rejected', reviewed_by: reviewer, reviewed_at: Time.current)
    MailLogEntry.log!(self, 'rejected', actor: reviewer, details: 'Rejected, not sent')
  end

  def log_edit!(actor)
    MailLogEntry.log!(self, 'edited', actor: actor, details: 'Message content edited')
  end

  def regenerate!(actor: nil)
    if email_template && recipient
      regenerate_from_email_template!
    elsif recipient
      regenerate_from_mailer!
    end
    MailLogEntry.log!(self, 'regenerated', actor: actor, details: 'Regenerated from template')
  end

  def can_regenerate?
    recipient.present? && (email_template.present? || mailer_action.present?)
  end

  def deliver_now!
    return if MailRecipientGuard.block_delivery_to!(self)

    increment!(:send_attempts)
    QueuedMailMailer.deliver_queued(self).deliver_now
    sent_time = Time.current
    update!(sent_at: sent_time, last_error: nil, last_error_at: nil)
    MailLogEntry.log_queued_delivery!(self)
    record_reminder_deliveries!(sent_time)
  rescue StandardError => e
    record_delivery_failure!(e) unless sent?
    raise
  end

  def retry_delivery!
    update!(last_error: nil, last_error_at: nil)
    QueuedMailDeliveryJob.perform_later(id)
  end

  def record_delivery_failure!(error)
    MailerDeliveryMonitor.record_failure!(error, source: "QueuedMail##{id}")
    error_message = "#{error.class}: #{error.message}"
    update!(last_error: error_message, last_error_at: Time.current)
    MailLogEntry.log_once!(self, 'send_failed', details: error_message)
  end

  def regenerate_from_email_template!
    args = (mailer_args || {}).symbolize_keys
    variables = MemberMailer.build_template_variables(recipient, args)
    self.class.ensure_admin_new_application_application_url!(variables, mailer_action, args)
    rendered = email_template.render(variables)
    update!(
      subject: rendered[:subject],
      body_html: rendered[:body_html],
      body_text: rendered[:body_text] || ''
    )
  end

  def regenerate_from_mailer!
    message = MemberMailer.public_send(
      mailer_action,
      *self.class.build_mailer_args(mailer_action, recipient, to, (mailer_args || {}).symbolize_keys)
    )
    msg = message.message
    html_body = msg.multipart? ? msg.html_part&.body&.decoded : msg.body.decoded
    text_body = msg.multipart? ? msg.text_part&.body&.decoded : ''
    update!(subject: msg.subject, body_html: html_body || '', body_text: text_body || '')
  end

  private :regenerate_from_email_template!, :regenerate_from_mailer!

  def self.enqueue_render_variables(action, user, extra_args, template)
    variables = MemberMailer.build_template_variables(user, extra_args)
    ensure_admin_new_application_application_url!(variables, action, extra_args) if template
    variables
  end

  # Some mailer actions accept a trailing options hash positionally (opts = {}) while others use
  # keyword arguments (e.g. training_completed(user, training_topic:)). build_mailer_args returns the
  # options as a trailing Hash; splat it as keywords so keyword-based mailers receive it correctly.
  # Ruby forwards **hash as a positional Hash to mailers that don't declare keyword params, so this
  # is safe for both styles.
  def self.dispatch_mailer(action, mailer_args)
    if mailer_args.last.is_a?(Hash)
      *positional, keyword_args = mailer_args
      MemberMailer.public_send(action, *positional, **keyword_args)
    else
      MemberMailer.public_send(action, *mailer_args)
    end
  end

  def self.build_mailer_args(action, user, to_addr, extra_args)
    case action.to_s
    when 'admin_new_application'
      [user, to_addr || extra_args[:admin_email], extra_args.slice(:application_url)]
    when 'payment_past_due'
      [user, { days_overdue: extra_args[:days_overdue] }.compact]
    when 'membership_cancelled', 'membership_banned', 'application_rejected'
      [user, { reason: extra_args[:reason] }.compact]
    when 'training_completed', 'trainer_capability_granted'
      [user, { training_topic: extra_args[:training_topic] }.compact]
    when 'training_requested'
      [user, extra_args.slice(:training_topic, :requester_name, :requester_email, :requester_slack,
                              :share_contact_info, :recipient_role, :trainer_names, :to)]
    when 'parking_permit_issued', 'parking_ticket_issued',
         'parking_permit_expired', 'parking_ticket_expired',
         'parking_permit_expiring_soon', 'parking_ticket_expiring_soon',
         'parking_permit_overdue_reminder', 'parking_ticket_overdue_reminder',
         'parking_permit_final_reminder', 'parking_ticket_final_reminder'
      [user, extra_args.slice(:location, :location_detail, :description, :expires_at, :notice_type,
                              :parking_notice_id)]
    when 'login_link_sent'
      [user, extra_args.slice(:login_url)]
    else
      [user]
    end
  end
end
