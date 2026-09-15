class QueuedMail
  # Delivers a template marked +send_immediately+ on the spot instead of parking it for review.
  #
  # Recording training, approving an application, banning a member: these all raise mail as a side
  # effect of something else, so a mail server that is disabled or unreachable must neither take
  # the request down with it nor drop the message. When the send cannot happen the rendered message
  # becomes an approved +QueuedMail+ carrying the failure, and +QueuedMailRetrySweepJob+ keeps
  # trying it. It does not go back for review — the template already said it may send unreviewed.
  class ImmediateSend
    def self.call(template, dest, variables, **options)
      new(template, dest, variables, options).call
    end

    # +options+ carries the delivery context: +mailer_action+, +user+, +verification_token+, and the
    # +queued_mail_attrs+ to fall back on.
    def initialize(template, dest, variables, options = {})
      @template = template
      @dest = dest
      @variables = variables
      @mailer_action = (options[:mailer_action].presence || template.key).to_s
      @user = options[:user]
      @verification_token = options[:verification_token]
      @queued_mail_attrs = options[:queued_mail_attrs]
    end

    # Returns a +QueuedMail::ImmediateDelivery+ when the message went out, or the +QueuedMail+
    # record holding it for retry when it could not.
    def call
      blocked_reason = MailDeliveryReadiness.unavailable_reason
      return queue_for_retry("Not attempted: #{blocked_reason}") if blocked_reason

      error = attempt_delivery
      return queue_for_retry("#{error.class}: #{error.message}") if error

      immediate_delivery
    end

    private

    attr_reader :template, :dest, :mailer_action

    # Returns the exception instead of raising it so the caller can queue the message; the mailer's
    # own logging and +MailerDeliveryMonitor+ have already recorded the failure by this point.
    def attempt_delivery
      EmailTemplateMailer.send_rendered(rendered_mail).deliver_now
      nil
    rescue StandardError => e
      Rails.logger.warn(
        "[QueuedMail] immediate #{mailer_action} to #{dest} could not be sent, queued for retry — " \
        "#{e.class}: #{e.message}"
      )
      e
    end

    def rendered
      @rendered ||= template.render(@variables)
    end

    def rendered_mail
      EmailTemplateMailer::RenderedMail.new(
        to: dest,
        subject: rendered[:subject],
        body_html: rendered[:body_html],
        body_text: body_text,
        mailer_action: mailer_action,
        user: @user,
        verification_token: @verification_token
      )
    end

    def immediate_delivery
      QueuedMail::ImmediateDelivery.new(
        to: dest,
        subject: rendered[:subject],
        body_html: rendered[:body_html],
        body_text: body_text,
        email_template: template
      )
    end

    def queue_for_retry(error_message)
      record = QueuedMail.create!(
        **queued_mail_attrs,
        status: 'approved',
        subject: rendered[:subject],
        body_html: rendered[:body_html],
        body_text: body_text,
        email_template: template,
        last_error: error_message,
        last_error_at: Time.current
      )
      MailLogEntry.log!(record, 'created',
                        details: "Queued #{mailer_action.humanize} to #{dest} for retry — #{error_message}")
      MailRecipientGuard.block_delivery_to!(record)
      record
    end

    # Callers that queue on their own behalf pass the same attributes they would have used for a
    # reviewed message, so a retried message keeps its reason and its mailer arguments.
    def queued_mail_attrs
      @queued_mail_attrs ||
        QueuedMail.queued_mail_attrs(dest, mailer_action.humanize, recipient_user, mailer_action, {})
    end

    def recipient_user
      @user if @user.is_a?(User)
    end

    def body_text
      rendered[:body_text] || ''
    end
  end
end
