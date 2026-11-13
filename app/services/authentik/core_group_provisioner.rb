module Authentik
  class CoreGroupProvisioner
    SYSTEM_APP_NAME = 'Member Zone'.freeze
    # Pre-rename value of SYSTEM_APP_NAME.
    LEGACY_SYSTEM_APP_NAME = 'Member Manager'.freeze

    # The application every core and training group hangs off. A database written before the
    # Member Zone rename still names it 'Member Manager', and applications.name carries no
    # unique index, so looking it up by the new name alone would quietly create a second
    # application and rebuild every group under it — orphaning the originals and leaving two
    # ApplicationGroups pushing to the same Authentik group. Adopt the old row instead.
    # The system application if provisioning has already created it. Does not create or rename,
    # so a page that only lists core groups stays read-only.
    def self.existing_system_application
      Application.find_by(name: SYSTEM_APP_NAME) || Application.find_by(name: LEGACY_SYSTEM_APP_NAME)
    end

    def self.system_application
      existing = Application.find_by(name: SYSTEM_APP_NAME)
      return existing if existing

      legacy = Application.find_by(name: LEGACY_SYSTEM_APP_NAME)
      return legacy.tap { |app| app.update!(name: SYSTEM_APP_NAME) } if legacy

      Application.create!(name: SYSTEM_APP_NAME)
    end

    attr_reader :defaults, :application, :results

    def initialize
      @defaults = DefaultSetting.instance
      @results = { created: [], existing: [], synced: [], errors: [] }
    end

    def provision!
      @application = find_or_create_system_application

      provision_static_groups
      provision_training_groups

      Rails.logger.info("[Authentik::CoreGroupProvisioner] Results: #{results.inspect}")
      results
    end

    def provision_and_sync!
      provision!
      sync_all!
      results
    end

    private

    def find_or_create_system_application
      self.class.system_application
    end

    def provision_static_groups
      ensure_group(
        name: 'Active Members',
        authentik_name: defaults.active_members_group,
        member_source: 'active_members'
      )
      ensure_group(
        name: 'Admins',
        authentik_name: defaults.admins_group,
        member_source: 'admin_members'
      )
      ensure_group(
        name: 'Unbanned Members',
        authentik_name: defaults.unbanned_members_group,
        member_source: 'unbanned_members'
      )
      ensure_group(
        name: 'All Members',
        authentik_name: defaults.all_members_group,
        member_source: 'all_members'
      )
    end

    def provision_training_groups
      TrainingTopic.find_each do |topic|
        slug = topic.name.parameterize

        ensure_group(
          name: "Trained: #{topic.name}",
          authentik_name: "#{defaults.trained_on_prefix}:#{slug}",
          member_source: 'trained_in',
          training_topic: topic
        )

        ensure_group(
          name: "Can Train: #{topic.name}",
          authentik_name: "#{defaults.can_train_prefix}:#{slug}",
          member_source: 'can_train',
          training_topic: topic
        )
      end
    end

    def ensure_group(name:, authentik_name:, member_source:, training_topic: nil)
      scope = application.application_groups.where(member_source: member_source)
      scope = scope.where(training_topic: training_topic) if training_topic

      group = scope.first
      if group
        group.update!(authentik_name: authentik_name) if group.authentik_name != authentik_name
        results[:existing] << group.name
      else
        group = application.application_groups.create!(
          name: name,
          authentik_name: authentik_name,
          member_source: member_source,
          training_topic: training_topic
        )
        results[:created] << group.name
      end
      group
    rescue StandardError => e
      results[:errors] << "#{name}: #{e.message}"
      Rails.logger.error("[Authentik::CoreGroupProvisioner] Failed to ensure group '#{name}': #{e.message}")
      nil
    end

    def sync_all!
      application.application_groups.find_each do |group|
        sync = Authentik::GroupSync.new(group)
        result = sync.sync!
        results[:synced] << "#{group.name}: #{result[:status]}"
      rescue StandardError => e
        results[:errors] << "Sync #{group.name}: #{e.message}"
      end
    end
  end
end
