module AuditLogs
  # Checks entries that have not been checked yet against a source's enabled alert rules and
  # sends each recipient one email covering every match.
  #
  # Nothing is stamped until the emails have been handed off. An entry is marked checked (and
  # matched entries marked alerted) only after that, so a failure partway — the job queue being
  # down, say — leaves the entries unchecked and the next run picks them up again. The price is
  # that a recipient reached before the failure may be mailed twice; the alternative is an alert
  # that is silently lost, since ingest only ever offers an entry once.
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
      return [] if @entries.empty?

      matched = match_entries
      notify(matched.keys) if matched.any?
      stamp(matched)
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

    def notify(entries)
      ids = entries.map(&:id)
      AlertRecipients.call(@source).each do |recipient|
        MemberMailer.audit_log_alert(recipient, @source, ids).deliver_later
      end
    end

    def stamp(matched)
      now = Time.current
      @entries.each do |entry|
        rule_ids = matched[entry]
        attributes = { alert_checked_at: now, updated_at: now }
        attributes.merge!(matched_rule_ids: rule_ids, alerted_at: now) if rule_ids
        entry.update_columns(attributes)
      end
    end
  end
end
