module Reports
  # Whether each member can actually get into the building: a key fob issued, the building
  # access training recorded, or both. Two queries for a whole page rather than two per row.
  #
  # The two signals can disagree, and the disagreement is the interesting part — a fob with
  # no training behind it is somebody who got a key without the process that should confer
  # one.
  class BuildingAccessStatus
    Status = Struct.new(:key, :trained_at) do
      def key? = key
      def trained? = trained_at.present?
      def any? = key || trained?
    end

    NONE = Status.new(false, nil).freeze

    def self.for(users)
      new(users).call
    end

    def initialize(users)
      @user_ids = users.map(&:id)
    end

    def call
      dates = trained_at_by_user
      @user_ids.index_with { |id| Status.new(keyed.include?(id), dates[id]) }
    end

    private

    def keyed
      @keyed ||= Rfid.where(user_id: @user_ids).distinct.pluck(:user_id).to_set
    end

    # No configured topic and no topic matching by name means nobody can be shown as
    # trained; the report still reports fobs.
    def trained_at_by_user
      topic = TrainingTopic.building_access
      return {} if topic.nil?

      Training.where(trainee_id: @user_ids, training_topic_id: topic.id)
              .group(:trainee_id)
              .maximum(:trained_at)
    end
  end
end
