module AuditLogEntriesHelper
  FILTER_PARAMS = %w[source state q from to].freeze

  # A link to the log with the current filters kept and some replaced or dropped.
  def audit_log_filter_path(**overrides)
    kept = request.query_parameters.slice(*FILTER_PARAMS)
    audit_log_entries_path(kept.merge(overrides.stringify_keys).compact_blank)
  end

  def audit_log_filters_active?
    FILTER_PARAMS.any? { |key| params[key].present? }
  end
end
