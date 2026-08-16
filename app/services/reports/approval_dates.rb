module Reports
  # When each member's application was accepted, for a whole page of members at once.
  #
  # User#membership_approved_at falls back to created_at so email copy always has a date to
  # work with. A report cannot do that: "accepted" has to mean an application really was
  # approved, so members who arrived some other way come back nil and the column says so.
  class ApprovalDates
    def self.for(users)
      new(users).call
    end

    def initialize(users)
      @user_ids = users.map(&:id)
    end

    def call
      return {} if @user_ids.empty?

      MembershipApplication.where(user_id: @user_ids, status: 'approved')
                           .group(:user_id)
                           .maximum(:reviewed_at)
    end
  end
end
