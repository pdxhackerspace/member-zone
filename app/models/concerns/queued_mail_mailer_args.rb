module QueuedMailMailerArgs
  extend ActiveSupport::Concern

  PARKING_MAILER_ACTIONS = %w[
    parking_permit_issued parking_ticket_issued
    parking_permit_expired parking_ticket_expired
    parking_permit_expiring_soon parking_ticket_expiring_soon
    parking_permit_overdue_reminder parking_ticket_overdue_reminder
    parking_permit_final_reminder parking_ticket_final_reminder
  ].freeze

  class_methods do
    def dispatch_mailer(action, mailer_args)
      if mailer_args.last.is_a?(Hash)
        *positional, keyword_args = mailer_args
        MemberMailer.public_send(action, *positional, **keyword_args)
      else
        MemberMailer.public_send(action, *mailer_args)
      end
    end

    def build_mailer_args(action, user, to_addr, extra_args)
      return parking_mailer_args(user, extra_args) if PARKING_MAILER_ACTIONS.include?(action.to_s)

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
      when 'login_link_sent'
        [user, extra_args.slice(:login_url)]
      else
        [user]
      end
    end

    def parking_mailer_args(user, extra_args)
      [user, extra_args.slice(:location, :location_detail, :description, :expires_at, :notice_type,
                              :parking_notice_id)]
    end
  end
end
