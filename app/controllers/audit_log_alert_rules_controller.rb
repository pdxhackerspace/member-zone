# Alert rules for one audit log source, managed from the source's page.
class AuditLogAlertRulesController < AuthenticatedController
  before_action -> { require_privilege!(:'audit_logs.manage') }
  before_action :set_source
  before_action :set_rule, only: %i[update destroy]

  def create
    rule = @source.audit_log_alert_rules.build(rule_params)
    if rule.save
      redirect_to audit_log_source_path(@source), notice: "Alert rule '#{rule.name}' added."
    else
      redirect_to audit_log_source_path(@source), alert: rule.errors.full_messages.to_sentence
    end
  end

  def update
    if @rule.update(rule_params)
      redirect_to audit_log_source_path(@source), notice: "Alert rule '#{@rule.name}' updated."
    else
      redirect_to audit_log_source_path(@source), alert: @rule.errors.full_messages.to_sentence
    end
  end

  def destroy
    @rule.destroy
    redirect_to audit_log_source_path(@source), notice: "Alert rule '#{@rule.name}' removed."
  end

  private

  def set_source
    @source = AuditLogSource.find(params[:audit_log_source_id])
  end

  def set_rule
    @rule = @source.audit_log_alert_rules.find(params[:id])
  end

  def rule_params
    params.expect(audit_log_alert_rule: %i[name pattern case_insensitive enabled])
  end
end
