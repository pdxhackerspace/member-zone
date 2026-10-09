module Credentials
  # Revokes, pauses or resumes one member's credentials after their standing changed.
  class MemberSyncJob < ApplicationJob
    queue_as :default

    def perform(user_id)
      user = User.find_by(id: user_id)
      MemberSync.call(user) if user
    end
  end
end
