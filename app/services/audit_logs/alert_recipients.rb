module AuditLogs
  # Who is emailed when a rule for this source matches: everyone holding audit_logs.alerts_all,
  # holders of audit_logs.alerts through the source's topic (or its parent, matching how
  # topic-scoped privileges reach one level of subtopics), and administrators, who hold
  # every privilege. Only active accounts with an address are returned.
  class AlertRecipients
    GLOBAL_KEY = 'audit_logs.alerts_all'.freeze
    TOPIC_KEY = 'audit_logs.alerts'.freeze

    def self.call(source)
      new(source).call
    end

    def initialize(source)
      @source = source
    end

    def call
      ids = User.with_privilege(GLOBAL_KEY).select(:id).or(User.where(is_admin: true).select(:id))
      ids = ids.or(topic_holders.select(:id)) if @source.training_topic

      User.where(id: ids, active: true).select { |user| user.email.present? }
    end

    private

    def topic_holders
      topic_ids = [@source.training_topic.id, @source.training_topic.parent_id].compact
      attachments = TrainingTopicRole.joins(role: :privileges)
                                     .where(privileges: { key: TOPIC_KEY }, training_topic_id: topic_ids)
      trained = Training.where(training_topic_id: attachments.trained_in.select(:training_topic_id))
                        .select(:trainee_id)
      trainers = TrainerCapability.where(training_topic_id: attachments.can_train.select(:training_topic_id))
                                  .select(:user_id)

      User.where(id: trained).or(User.where(id: trainers))
    end
  end
end
