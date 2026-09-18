class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV.fetch('EMAIL_FROM_ADDRESS', 'noreply@example.com') }
  layout 'mailer'

  after_action :set_member_zone_mail_trace_headers
  around_deliver :log_member_zone_mail_delivery

  def mail(headers = {}, &)
    assign_email_banner
    assign_notification_footer_context
    super
  end

  private

  def set_member_zone_mail_trace_headers
    headers['X-MemberZone-Mailer'] = self.class.name
    headers['X-MemberZone-Action'] = action_name.to_s
  end

  def log_member_zone_mail_delivery(&)
    if mail_recipient_blocked?
      log_direct_mail_delivery!(
        'rejected',
        details: MailRecipientGuard.rejection_details_for_direct(
          to: message.to,
          mailer_class: self.class.name,
          mailer_action: action_name
        )
      )
      return
    end

    if notification_opt_out_blocked?
      log_direct_mail_delivery!('suppressed', details: notification_opt_out_rejection_details)
      return
    end

    deliver_and_record_outcome(&)
  end

  # Only the handoff is inside the rescue. Logging the success used to sit there too, so a failed
  # log write reported a delivered message as failed — and on the immediate-send path that queued
  # an approved copy for the retry sweep to deliver a second time.
  def deliver_and_record_outcome
    yield
  rescue StandardError => e
    MailerDeliveryMonitor.record_failure!(e, source: "#{self.class.name}##{action_name}")
    raise unless capture_failed_delivery!(e)
  else
    log_delivered!
  end

  def log_delivered!
    log_direct_mail_delivery!('sent')
  rescue StandardError => e
    Rails.logger.error(
      "[Mailer] delivery log entry failed for #{self.class.name}##{action_name} — #{e.class}: #{e.message}"
    )
  end

  # Parks a direct delivery the mail server would not take in the mail queue, so the message is
  # still there to look at and retry and +QueuedMailRetrySweepJob+ is the only thing retrying it.
  # Returns nil when the caller already holds a queue record for this message, or when there is no
  # body to store — in both cases the exception is re-raised as before.
  def capture_failed_delivery!(error)
    return nil if message['X-MemberZone-Skip-MailQueue']&.decoded.to_s == '1'
    return nil if message.to.blank? || message.subject.blank?

    QueuedMail.capture_failed_delivery(
      to: Array(message.to).compact.join(', '),
      subject: message.subject.to_s,
      body_html: mail_body_html,
      body_text: mail_body_text,
      mailer_action: effective_mailer_action,
      recipient: notification_recipient_user,
      error: error
    )
  rescue StandardError => e
    Rails.logger.error(
      "[Mailer] could not queue failed #{self.class.name}##{action_name} for retry — #{e.class}: #{e.message}"
    )
    nil
  end

  def log_direct_mail_delivery!(event, details: nil)
    return if message['X-MemberZone-Skip-MailLog']&.decoded.to_s == '1'
    return if message.to.blank? || message.subject.blank?

    MailLogEntry.log_direct_delivery!(
      to: Array(message.to).compact.join(', '),
      subject: message.subject.to_s.truncate(500),
      mailer_class: self.class.name,
      mailer_action: action_name.to_s,
      event: event,
      details: details,
      body_html: mail_body_html,
      body_text: mail_body_text
    )
  end

  def mail_recipient_blocked?
    MailRecipientGuard.block_direct_delivery!(
      to: message.to,
      subject: message.subject,
      mailer_class: self.class.name,
      mailer_action: action_name
    )
  end

  def notification_opt_out_blocked?
    return false if admin_facing_mailer_action?

    Notifications::DeliveryGate.blocked?(
      mailer_action: effective_mailer_action,
      user: notification_recipient_user,
      email: notification_recipient_email
    )
  end

  def admin_facing_mailer_action?
    MailRecipientGuard::ADMIN_MAILER_ACTIONS.include?(effective_mailer_action)
  end

  def effective_mailer_action
    @notification_mailer_action.presence || action_name
  end

  def notification_recipient_user
    return @notification_recipient_user if @notification_recipient_user.present?
    return @user if defined?(@user) && @user.respond_to?(:email)

    nil
  end

  def notification_opt_out_rejection_details
    "Suppressed: recipient opted out of #{effective_mailer_action}"
  end

  def notification_recipient_email
    Array(message.to).compact.first || @notification_recipient_user&.email || @email
  end

  def assign_email_banner
    @email_banner = Emails::BannerPresenter.for_email
  end

  def assign_notification_footer_context
    user = @notification_recipient_user
    user = @user if user.blank? && defined?(@user) && @user.respond_to?(:email)
    email = @email if user.blank? && defined?(@email)
    email ||= user&.email if user.respond_to?(:email)

    @notification_footer = Notifications::DeliveryGate.footer_for(
      mailer_action: effective_mailer_action,
      user: user,
      email: email,
      verification_token: @notification_verification_token
    )
  end

  def append_notification_footer(text)
    footer = @notification_footer&.text.to_s
    return text if footer.blank?

    "#{text}\n\n#{footer}".strip
  end

  def plain_text_email_body(body = nil)
    Emails::BodyComposer.text(body: body, banner: @email_banner, footer: @notification_footer)
  end

  def mail_body_html
    return message.html_part&.body&.decoded if message.multipart?
    return message.body.decoded if message.mime_type == 'text/html'

    nil
  end

  def mail_body_text
    return message.text_part&.body&.decoded if message.multipart?
    return message.body.decoded if message.mime_type == 'text/plain'

    nil
  end

  # Helper to get the organization name for emails
  def organization_name
    ENV.fetch('ORGANIZATION_NAME', 'Member Zone')
  end

  # Helper to get the support email
  def support_email
    ENV.fetch('EMAIL_SUPPORT_ADDRESS', ENV.fetch('EMAIL_FROM_ADDRESS', 'support@example.com'))
  end
end
