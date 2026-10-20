module AccessControllers
  # Pushes the full member key payload to every enabled access controller after a member's
  # RFID keys change or key access is paused or resumed.
  module MemberKeysSync
    module_function

    def enqueue!(actor_user_id: nil)
      count = 0
      syncable_controllers.find_each do |controller|
        AccessControllerVerbJob.perform_later(controller.id, 'sync', actor_user_id)
        count += 1
      end
      count
    end

    def syncable_controllers
      AccessController.enabled.joins(:access_controller_type).merge(AccessControllerType.enabled)
    end

    def user_notice(count)
      if count.positive?
        " #{count} access controller#{'s' if count != 1} #{count == 1 ? 'is' : 'are'} syncing in the background."
      else
        ' No enabled access controllers to sync — configure them under Settings → Access Controllers.'
      end
    end
  end
end
