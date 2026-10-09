module ParkingPermits
  # Handles a parking permit request from an access control device on behalf of the member who
  # badged in. The device chooses one of two modes:
  #
  # * +link+  — email the member a 12-hour, no-login link to a form that creates the permit and
  #             lets them print it. Nothing is created until they submit.
  # * +blank+ — issue a permit right away, valid for the self-service maximum, for the member to
  #             hand-write. They are emailed a link to record the details online, and
  #             Reminders::ParkingPermitDetailsEligibility nudges them until they do.
  class DeviceIssuer
    MODES = %w[link blank].freeze

    Result = Data.define(:status, :error, :mode, :user, :parking_notice, :link) do
      def success? = status == :created
    end

    def self.call(...)
      new(...).call
    end

    def initialize(device:, mode:, member_params:, now: Time.current)
      @device = device
      @mode = mode.to_s.strip.downcase
      @member_params = member_params
      @now = now
    end

    # The mailer arguments every device-issued permit email shares. Public so the reminder can
    # build the same arguments around the fresh link it mints.
    def self.link_mail_args(link)
      notice = link.parking_notice
      {
        permit_form_url: link.url,
        permit_form_expires_at: link.expires_at.in_time_zone.strftime('%B %-d, %Y at %-l:%M %p'),
        permit_expires_at: notice&.expires_at&.strftime('%B %d, %Y').to_s,
        device_name: link.webhook_device&.name.to_s
      }
    end

    def call
      return failure(:bad_request, "mode must be one of: #{MODES.join(', ')}") unless MODES.include?(@mode)

      lookup = MemberLookup.call(**@member_params)
      return failure(lookup.status, lookup.error) unless lookup.user

      user = lookup.user
      return failure(:unprocessable_content, 'member is not eligible for a parking permit') unless eligible?(user)

      @mode == 'link' ? issue_link(user) : issue_blank(user)
    end

    private

    def eligible?(user)
      MembershipState::TERMINAL_STATES.exclude?(user.membership_state)
    end

    def issue_link(user)
      return failure(:unprocessable_content, 'member has no email address to send the link to') if user.email.blank?

      link = ParkingPermitLink.issue_for_new_permit!(user: user, webhook_device: @device, now: @now)
      MemberMailer.parking_permit_form_link(user, **link_mail_args(link)).deliver_later
      Result.new(status: :created, error: nil, mode: @mode, user: user, parking_notice: nil, link: link)
    end

    def issue_blank(user)
      notice, link = ParkingNotice.transaction do
        notice = create_blank_permit!(user)
        [notice, (ParkingPermitLink.issue_for_blank_permit!(notice, now: @now) if user.email.present?)]
      end

      notice.record_journal_entry!('parking_permit_issued')
      if link
        MemberMailer.parking_permit_blank_issued(user, **link_mail_args(link), parking_notice_id: notice.id)
                    .deliver_later
      end
      Result.new(status: :created, error: nil, mode: @mode, user: user, parking_notice: notice, link: link)
    end

    def create_blank_permit!(user)
      notice = ParkingNotice.create!(
        notice_type: 'permit', status: 'active', user: user, issued_by: user, webhook_device: @device,
        expires_at: @now + ParkingNotice::MAX_SELF_SERVICE_DURATION, details_requested_at: @now
      )
      notice.log_event!('note', note: "Blank permit issued by #{@device.name}.")
      notice
    end

    def link_mail_args(link)
      self.class.link_mail_args(link)
    end

    def failure(status, error)
      Result.new(status: status, error: error, mode: @mode, user: nil, parking_notice: nil, link: nil)
    end
  end
end
