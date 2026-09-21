module Reminders
  # The SQL half of Schedule. A daily run cannot afford to load every member and ask Schedule
  # about each one, so this narrows a relation down to the subjects whose cadence could
  # plausibly be due and leaves the exact answer to Schedule#due?.
  #
  # Being deliberately loose is the point: it must never drop a subject that is actually due.
  # Anything it lets through is checked again in Ruby.
  class DeliveryScope
    ELAPSED_SQL = '(reminder_deliveries.last_sent_at IS NULL OR reminder_deliveries.last_sent_at <= :cutoff)'.freeze

    # +anchor_sql+ is an optional SQL expression for the subject's anchor. Supplying it lets a
    # subject whose anchor has moved back into the candidate set even though its sequence had
    # already run to its maximum — an admin extending a parking notice, say.
    def self.candidates(relation, key:, anchor_sql: nil, now: Time.current)
      setting = ReminderSetting.for_key(key)
      return relation.none if setting.nil?

      relation.joins(join_sql(relation, key))
              .where(due_sql(setting, anchor_sql: anchor_sql, now: now))
    end

    def self.join_sql(relation, key)
      model = relation.klass

      ActiveRecord::Base.sanitize_sql_array(
        [
          <<~SQL.squish,
            LEFT OUTER JOIN reminder_deliveries
              ON reminder_deliveries.reminder_key = ?
             AND reminder_deliveries.subject_type = ?
             AND reminder_deliveries.subject_id = #{model.quoted_table_name}.#{model.primary_key}
          SQL
          key, model.polymorphic_name
        ]
      )
    end

    def self.due_sql(setting, anchor_sql:, now:)
      clauses = ['reminder_deliveries.id IS NULL']
      clauses << "reminder_deliveries.anchor_at IS DISTINCT FROM (#{anchor_sql})" if anchor_sql.present?
      clauses << ActiveRecord::Base.sanitize_sql_array(
        [in_sequence_sql(setting), { cutoff: now - setting.interval_days.days }]
      )

      "(#{clauses.join(' OR ')})"
    end

    def self.in_sequence_sql(setting)
      return ELAPSED_SQL if setting.unlimited_reminders?

      "(reminder_deliveries.sent_count < #{setting.max_reminders.to_i} AND #{ELAPSED_SQL})"
    end

    private_class_method :join_sql, :due_sql, :in_sequence_sql
  end
end
