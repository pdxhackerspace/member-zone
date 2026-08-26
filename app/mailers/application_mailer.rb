class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV.fetch('EMAIL_FROM_ADDRESS', 'noreply@example.com') }
  layout 'mailer'

  after_action :set_member_zone_mail_trace_headers
  around_deliver :log_member_zone_mail_delivery

  def mail(headers = {}, &)
    assign_notification_footer_context
    super
  end

  private

  def set_member_zone_mail_trace_headers
    headers['X-MemberZone-Mailer'] = self.class.name
    headers['X-MemberZone-Action'] = action_name.to_s
  end

  def log_member_zone_mail_delivery
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

    yield
    log_direct_mail_delivery!('sent')
  rescue StandardError => e
    MailerDeliveryMonitor.record_failure!(e, source: "#{self.class.name}##{action_name}")
    log_direct_mail_delivery!('send_failed', details: "#{e.class}: #{e.message}")
    raise
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
    return false if MailRecipientGuard.admin_facing_delivery?(mailer_class: self.class.name, mailer_action: action_name)

    Notifications::DeliveryGate.blocked?(
      mailer_action: action_name,
      user: notification_recipient_user,
      email: notification_recipient_email
    )
  end

  def notification_recipient_user
    return @notification_recipient_user if @notification_recipient_user.present?
    return @user if defined?(@user) && @user.respond_to?(:email)

    nil
  end

  def notification_opt_out_rejection_details
    "Suppressed: recipient opted out of #{action_name}"
  end

  def notification_recipient_email
    Array(message.to).compact.first || @notification_recipient_user&.email || @email
  end

  def assign_notification_footer_context
    user = @notification_recipient_user
    user = @user if user.blank? && defined?(@user) && @user.respond_to?(:email)
    email = @email if user.blank? && defined?(@email)
    email ||= user&.email if user.respond_to?(:email)

    @notification_footer = Notifications::DeliveryGate.footer_for(
      mailer_action: action_name,
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
