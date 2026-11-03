# Builds the JSON payload of users to sync to access controller scripts.
# Respects the global sync_inactive_members setting and per-type training requirements.
class AccessControllerPayloadBuilder
  def self.call(access_controller_type: nil)
    new(access_controller_type: access_controller_type).build
  end

  def initialize(access_controller_type: nil)
    @access_controller_type = access_controller_type
  end

  def build
    JSON.generate(build_entries)
  end

  private

  def build_entries
    base_users.each_with_object([]) do |user, entries|
      next unless user.rfids.any?
      next unless meets_training_requirements?(user)

      entries << user_entry(user)
    end
  end

  def base_users
    scope = sync_inactive_members? ? User.all : User.active
    # Members with paused key access are never synced to access controllers,
    # even when active and otherwise eligible.
    scope.key_access_active.includes(:rfids, trainings_as_trainee: :training_topic)
  end

  def sync_inactive_members?
    DefaultSetting.instance.sync_inactive_members
  end

  def meets_training_requirements?(user)
    return true unless @access_controller_type

    @access_controller_type.user_meets_training_requirements?(user)
  end

  def user_entry(user)
    {
      name: normalize_text(user.full_name.presence || user.display_name),
      uid: user.authentik_id.presence || user.id,
      rfids: user.rfids.map(&:rfid),
      permissions: user.trainings_as_trainee.filter_map { |t| normalize_text(t.training_topic&.name) }.uniq
    }
  end

  def normalize_text(value)
    AccessControllerTextNormalizer.call(value).presence
  end
end
