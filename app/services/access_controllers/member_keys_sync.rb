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

    def rfid_removed_notice
      key_change_notice('Key fob removed.', ' Access controllers are syncing to update door access.')
    end

    def pause_key_access_notice(display_name)
      key_change_notice(
        "Key access paused for #{display_name}. Their keys are kept.",
        ' Access controllers are syncing to remove door access.'
      )
    end

    def resume_key_access_notice(display_name)
      key_change_notice(
        "Key access resumed for #{display_name}.",
        ' Access controllers are syncing to restore door access.'
      )
    end

    def key_change_notice(prefix, syncing_phrase)
      count = syncable_controllers.count
      if count.positive?
        "#{prefix}#{syncing_phrase}#{user_notice(count)}"
      else
        "#{prefix}#{user_notice(count)}"
      end
    end
  end
end
