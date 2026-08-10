module Membership
  # Materializes one member's clock-driven state and cached projections. Shared by the
  # nightly TickJob and the preview/apply rake tasks so the rules live in one place.
  class StateTick
    EXPIRING_STATES = MembershipStateResolution::EXPIRY_TARGETS.keys.freeze
    Result = Struct.new(:status, :user, :from_state, :to_state, keyword_init: true) do
      def expired? = status == :expired
      def reconciled? = status == :reconciled
      def changed? = expired? || reconciled?
    end

    def self.call(user)
      new(user).call
    end

    def initialize(user)
      @user = user
    end

    def stale?
      return false if @user.service_account?

      @user.membership_state_expired? || @user.read_attribute(:active) != @user.compute_membership_active
    end

    def call
      return Result.new(status: :unchanged, user: @user) if @user.service_account?

      if @user.membership_state_expired?
        from = @user.membership_state
        to = @user.effective_membership_state
        @user.expire_membership_state!
        return Result.new(status: :expired, user: @user, from_state: from, to_state: to)
      end

      if @user.read_attribute(:active) != @user.compute_membership_active
        @user.save!
        return Result.new(status: :reconciled, user: @user)
      end

      Result.new(status: :unchanged, user: @user)
    end

    def summary_line
      parts = ["#{@user.display_name} (id #{@user.id})"]
      computed = @user.compute_membership_active
      stored = @user.read_attribute(:active)
      parts << "active #{stored} -> #{computed}" if stored != computed
      if @user.membership_state_expired?
        parts << "state #{@user.membership_state} -> #{@user.effective_membership_state}"
      end
      parts << 'payment_type -> inactive' if @user.deceased? && @user.payment_type != 'inactive'
      parts.join(', ')
    end
  end
end
