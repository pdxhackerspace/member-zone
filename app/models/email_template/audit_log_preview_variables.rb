class EmailTemplate
  # Sample values for the audit log alert template; see PreviewVariables for why every
  # variable needs one.
  module AuditLogPreviewVariables
    module_function

    def all
      {
        audit_source_name: 'Door controller syslog',
        audit_match_count: '2',
        audit_matches_html: '<ul><li><strong>September 29, 2026 09:14</strong><br>Failed login for root</li></ul>',
        audit_matches_text: "- September 29, 2026 09:14\n  Failed login for root",
        audit_log_url: "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000')}/audit_log_entries"
      }
    end
  end
end
