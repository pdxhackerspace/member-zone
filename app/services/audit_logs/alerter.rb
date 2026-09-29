module AuditLogs
  # Checks newly ingested entries against a source's enabled alert rules, stamps the entries
  # that matched, and sends each recipient one email covering every match from the run.
  class Alerter
    def self.call(source, entries)
      new(source, entries).call
    end

    def initialize(source, entries)
      @source = source
      @entries = entries.to_a
    end

    # Returns the entries that matched at least one rule.
    def call
      matched = match_entries
      return [] if matched.empty?

      record_matches(matched)
      notify(matched.keys)
      matched.keys
    end

    private

    def match_entries
      rules = @source.audit_log_alert_rules.enabled.to_a
      return {} if rules.empty?

      @entries.each_with_object({}) do |entry, matched|
        hits = rules.select { |rule| rule.matches?(entry.message) }
        matched[entry] = hits.map(&:id) if hits.any?
      end
    end

    def record_matches(matched)
      now = Time.current
      matched.each do |entry, rule_ids|
        entry.update_columns(matched_rule_ids: rule_ids, alerted_at: now, updated_at: now)
      end
    end

    def notify(entries)
      ids = entries.map(&:id)
      AlertRecipients.call(@source).each do |recipient|
        MemberMailer.audit_log_alert(recipient, @source, ids).deliver_later
      end
    end
  end
end
