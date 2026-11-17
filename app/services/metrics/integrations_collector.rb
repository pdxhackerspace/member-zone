module Metrics
  # The things Member Zone talks to: access controllers, printers, AI profiles, credential
  # providers, audit log sources, member sources and payment processors. Each already records
  # the outcome of its own health check or sync; this exports those in one shape.
  class IntegrationsCollector < Collector
    # kind: label value. status: the column holding the last outcome. up: values that mean
    # working. name: the column identifying the record. The rest are optional columns.
    SOURCES = [
      { kind: 'access_controller', model: 'AccessController', status: :ping_status, up: %w[success],
        checked_at: :last_ping_at },
      { kind: 'printer', model: 'Printer', status: :health_status, up: %w[healthy],
        checked_at: :last_health_check_at },
      { kind: 'ai_profile', model: 'AiOllamaProfile', name: :key, status: :health_status, up: %w[healthy],
        checked_at: :last_health_check_at },
      { kind: 'credential_provider', model: 'CredentialProvider', status: :health_status, up: %w[healthy],
        checked_at: :last_health_check_at, succeeded_at: :last_healthy_at },
      { kind: 'audit_log_source', model: 'AuditLogSource', status: :run_status, up: %w[success running],
        checked_at: :last_run_at },
      { kind: 'member_source', model: 'MemberSource', name: :key, status: :sync_status, up: %w[healthy],
        checked_at: :last_sync_at, succeeded_at: :last_successful_sync_at, errors: :consecutive_error_count },
      { kind: 'payment_processor', model: 'PaymentProcessor', name: :key, status: :sync_status, up: %w[healthy],
        checked_at: :last_sync_at, succeeded_at: :last_successful_sync_at, errors: :consecutive_error_count }
    ].freeze

    def collect
      SOURCES.each do |source|
        source[:model].constantize.find_each { |record| export(source, record) }
      end
      access_controllers
      payment_processors
    end

    private

    def families
      @families ||= {
        up: gauge('memberzone_integration_up', 'Whether the last health check or sync succeeded (1) or not (0).'),
        enabled: gauge('memberzone_integration_enabled', 'Whether the integration is switched on.'),
        status: gauge('memberzone_integration_status', 'Always 1; the status label is the last recorded outcome.'),
        checked: gauge('memberzone_integration_last_check_timestamp_seconds',
                       'When the integration was last checked or synced.'),
        succeeded: gauge('memberzone_integration_last_success_timestamp_seconds',
                         'When the integration last checked out healthy or synced successfully.'),
        errors: gauge('memberzone_integration_consecutive_errors', 'Failed syncs in a row.')
      }
    end

    def export(source, record)
      labels = { kind: source[:kind], name: record[source[:name] || :name].to_s }
      status = record[source[:status]].to_s
      families[:up].set(source[:up].include?(status), labels)
      families[:enabled].set(record.has_attribute?(:enabled) ? record.enabled : true, labels)
      families[:status].set(1, labels.merge(status: status))
      families[:checked].set(record[source[:checked_at]], labels)
      families[:succeeded].set(record[source[:succeeded_at]], labels) if source[:succeeded_at]
      families[:errors].set(record[source[:errors]], labels) if source[:errors]
    end

    def access_controllers
      sync = gauge('memberzone_access_controller_sync_status', 'Always 1; the status label is the last sync outcome.')
      backup = gauge('memberzone_access_controller_backup_status',
                     'Always 1; the status label is the last backup outcome.')
      synced = gauge('memberzone_access_controller_last_sync_timestamp_seconds', 'When the controller last synced.')
      backed_up = gauge('memberzone_access_controller_last_backup_timestamp_seconds',
                        'When the controller was last backed up.')
      AccessController.find_each do |controller|
        labels = { name: controller.name }
        sync.set(1, labels.merge(status: controller.sync_status.to_s))
        backup.set(1, labels.merge(status: controller.backup_status.to_s))
        synced.set(controller.last_sync_at, labels)
        backed_up.set(controller.last_backup_at, labels)
      end
    end

    def payment_processors
      payments = gauge('memberzone_payment_processor_payments', 'Payments seen from a processor, by match outcome.')
      recent = gauge('memberzone_payment_processor_amount_30d', 'Amount received through a processor in 30 days.')
      webhook = gauge('memberzone_payment_processor_webhook_last_timestamp_seconds',
                      'When a webhook was last received from the processor.')
      PaymentProcessor.find_each do |processor|
        labels = { processor: processor.key }
        payments.set(processor.matched_payments_count.to_i, labels.merge(match: 'matched'))
        payments.set(processor.unmatched_payments_count.to_i, labels.merge(match: 'unmatched'))
        recent.set(processor.amount_last_30_days.to_f, labels)
        webhook.set(processor.webhook_last_received_at, labels)
      end
    end
  end
end
