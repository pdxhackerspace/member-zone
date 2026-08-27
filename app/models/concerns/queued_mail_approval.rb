module QueuedMailApproval
  extend ActiveSupport::Concern

  class_methods do
    def approve_all!(relation, reviewer)
      counts = { approved: 0, blocked_recipient: 0, blocked_opt_out: 0 }
      relation.find_each do |queued_mail|
        if queued_mail.approve!(reviewer)
          counts[:approved] += 1
        elsif queued_mail.approval_blocked_reason == :opt_out
          counts[:blocked_opt_out] += 1
        else
          counts[:blocked_recipient] += 1
        end
      end
      counts
    end

    def approve_all_notice_extras(counts)
      extras = []
      if counts[:blocked_recipient].positive?
        extras << "#{counts[:blocked_recipient]} blocked for banned or deceased recipients."
      end
      if counts[:blocked_opt_out].positive?
        extras << "#{counts[:blocked_opt_out]} not sent because the recipient opted out."
      end
      extras.join(' ')
    end
  end

  def approve!(reviewer)
    return false if MailRecipientGuard.block_delivery_to!(self)
    return false if Notifications::DeliveryGate.block_queued_delivery!(self)

    update!(status: 'approved', reviewed_by: reviewer, reviewed_at: Time.current)
    MailLogEntry.log!(self, 'approved', actor: reviewer, details: "Approved for delivery to #{to}")
    QueuedMailDeliveryJob.perform_later(id)
    true
  end

  def approval_blocked_reason
    return unless rejected?

    return :opt_out if Notifications::DeliveryGate.opt_out_rejection?(self)
    return :recipient if MailRecipientGuard.blocked?(recipient || User.lookup_by_email(to))

    nil
  end

  def approval_blocked_alert
    case approval_blocked_reason
    when :opt_out
      Notifications::DeliveryGate.opt_out_alert_message(self)
    when :recipient
      MailRecipientGuard.blocked_recipient_alert_message(self)
    else
      'Message could not be approved.'
    end
  end
end
