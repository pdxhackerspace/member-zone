module Slack
  class MemberCreator
    Result = Struct.new(:status, :user, :message) do
      def success?
        status == :success
      end
    end

    def self.call(slack_user:)
      new(slack_user: slack_user).call
    end

    def initialize(slack_user:)
      @slack_user = slack_user
    end

    def call
      return Result.new(:failure, nil, 'Slack user is already linked to a member.') if @slack_user.user_id.present?

      user = build_user
      if user.save
        @slack_user.update!(user_id: user.id)
        Result.new(:success, user, nil)
      else
        Result.new(:failure, user, user.errors.full_messages.join(', '))
      end
    end

    private

    def build_user
      user = User.new(
        full_name: @slack_user.real_name,
        email: @slack_user.email,
        slack_id: @slack_user.slack_id,
        slack_handle: @slack_user.username,
        membership_state: User.initial_membership_state,
        payment_type: 'unknown'
      )

      profile = @slack_user.raw_attributes&.dig('profile') || {}
      user.avatar = profile['image_192'] if profile['image_original'].present? && profile['image_192'].present?
      user.pronouns = @slack_user.pronouns if @slack_user.pronouns.present?

      user
    end
  end
end
