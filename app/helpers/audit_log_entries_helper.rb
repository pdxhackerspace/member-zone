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

  # Journal row for a rewritten explanation; see AuditLogEntry#explain!.
  def render_audit_log_change(data)
    explanation = data['explanation'] || {}
    content_tag(:div, class: 'small') do
      safe_join([
                  content_tag(:strong, data['source']), ' ',
                  link_to('entry', audit_log_entry_path(data['id']), class: 'link-primary'),
                  content_tag(:div, data['message'], class: 'text-muted font-monospace'),
                  content_tag(:div, safe_join(['Was: ', display_change_value(explanation['from'])])),
                  content_tag(:div, safe_join(['Now: ', display_change_value(explanation['to'])]))
                ])
    end
  end
end
