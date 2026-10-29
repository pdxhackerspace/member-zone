class AccessControllerMemberKeysSyncJob < ApplicationJob
  queue_as :default

  def perform(actor_user_id = nil)
    AccessControllers::MemberKeysSync.enqueue!(actor_user_id: actor_user_id)
  end
end
