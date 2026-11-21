module TrainingResources
  # What the Reminders page says about the digest: how much is waiting, and whether
  # today's run would send it.
  class DigestSummary
    attr_reader :due_recipient_count, :pending_count, :topic_count, :next_digest_at, :due

    def initialize(pending_count:, topic_count:, due_recipient_count:, due:, next_digest_at:)
      @pending_count = pending_count
      @topic_count = topic_count
      @due_recipient_count = due_recipient_count
      @due = due
      @next_digest_at = next_digest_at
    end

    def context
      "#{pending_count} #{'change'.pluralize(pending_count)} waiting across " \
        "#{topic_count} #{'topic'.pluralize(topic_count)}"
    end

    def note
      return 'Nothing is waiting to send.' if pending_count.zero?
      return daily_run_note if due

      "Next digest #{next_digest_at.strftime("%b #{next_digest_at.day}")}. " \
        'Send now sends the waiting changes anyway.'
    end

    private

    def daily_run_note
      'The daily run will send one email per person covering every topic they train or are trained in.'
    end
  end
end
