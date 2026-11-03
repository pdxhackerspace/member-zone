module Announcers
  # The JSON an announcer program reads on stdin: who arrived, what to call them, and where.
  # Secrets never go here; they reach the program as environment variables.
  class PayloadBuilder
    def self.call(...)
      new(...).call
    end

    def initialize(announcer:, user:, access_log: nil, test_run: false)
      @announcer = announcer
      @user = user
      @access_log = access_log
      @test_run = test_run
    end

    def call
      {
        event: 'arrival',
        test: @test_run,
        announcer: @announcer.name,
        member: member,
        access: access
      }.to_json
    end

    private

    def member
      {
        id: @user.id,
        name: @user.greeting_name.presence || @user.username,
        username: @user.username,
        pronouns: @user.pronouns.presence,
        profile_url: profile_url,
        slack: slack
      }
    end

    def slack
      slack_user = @user.slack_user
      return nil if slack_user.nil? && @user.slack_handle.blank?

      { user_id: slack_user&.slack_id, handle: @user.slack_handle.presence || slack_user&.username }
    end

    # Only for profiles other people can already see; a private profile has nothing to link to.
    def profile_url
      return nil unless User::SHARED_PROFILE_VISIBILITIES.include?(@user.profile_visibility)

      "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000').chomp('/')}/users/#{ERB::Util.url_encode(@user.to_param)}"
    end

    def access
      return { location: nil, action: nil, logged_at: Time.current.iso8601 } if @access_log.nil?

      { location: @access_log.location, action: @access_log.action, logged_at: @access_log.logged_at&.iso8601 }
    end
  end
end
