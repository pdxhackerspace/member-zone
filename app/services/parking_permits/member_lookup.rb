module ParkingPermits
  # Finds the member a device request is about. Devices identify members by the key fob they
  # badged with; Slack UID, username, or full email address also work for devices that know who
  # is signed in some other way. Email lookup goes through the HMAC digest because the column is
  # encrypted.
  class MemberLookup
    Result = Data.define(:user, :status, :error)

    def self.call(rfid: nil, slack_uid: nil, username: nil, email: nil)
      new(rfid: rfid, slack_uid: slack_uid, username: username, email: email).call
    end

    def initialize(rfid:, slack_uid:, username:, email:)
      @rfid = rfid.to_s.strip
      @slack_uid = slack_uid.to_s.strip
      @username = username.to_s.strip
      @email = email.to_s.strip
    end

    def call
      return failure(:bad_request, 'rfid, slack_uid, username, or email is required') if identifiers_blank?

      users = candidates
      return failure(:not_found, 'member not found') if users.empty?
      return failure(:conflict, 'more than one member matches') if users.size > 1

      Result.new(user: users.first, status: :ok, error: nil)
    end

    private

    def identifiers_blank?
      @rfid.blank? && @slack_uid.blank? && @username.blank? && @email.blank?
    end

    def candidates
      return users_by_rfid if @rfid.present?
      return users_by_slack_uid if @slack_uid.present?
      return User.where('LOWER(username) = ?', @username.downcase).limit(2).to_a if @username.present?

      User.by_any_email(@email).limit(2).to_a
    end

    def users_by_slack_uid
      by_column = User.where(slack_id: @slack_uid).limit(2).to_a
      linked = SlackUser.find_by(slack_id: @slack_uid)&.user
      (by_column + [linked]).compact.uniq
    end

    # A fob can be on file for more than one account (a member who rejoined under a new one, say).
    # Prefer the active account; if that still leaves more than one, refuse rather than guess.
    def users_by_rfid
      normalized = RfidNormalizer.call(@rfid)&.downcase
      return [] if normalized.blank?

      users = User.joins(:rfids).where('LOWER(rfids.rfid) = ?', normalized).distinct.to_a
      active = users.select(&:active?)
      active.presence || users
    end

    def failure(status, error)
      Result.new(user: nil, status: status, error: error)
    end
  end
end
