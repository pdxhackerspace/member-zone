# Configures audit log sources: which program to run, how often, with what environment, and
# what to alert on. Environment variables hold secrets, so this stays behind audit_logs.manage
# alone and is never reachable through a topic-scoped privilege.
class AuditLogSourcesController < AuthenticatedController
  PREVIEW_TIMEOUT = 30
  RUNS_SHOWN = 20

  before_action -> { require_privilege!(:'audit_logs.manage') }
  before_action :set_source, only: %i[show edit update destroy toggle run preview]

  def index
    @sources = AuditLogSource.ordered.includes(:training_topic)
    @entry_counts = AuditLogEntry.group(:audit_log_source_id).count
  end

  def show
    @runs = @source.audit_log_runs.recent.limit(RUNS_SHOWN)
    @rules = @source.audit_log_alert_rules.order(:name)
    @new_rule = @source.audit_log_alert_rules.build
    @entry_count = @source.audit_log_entries.count
  end

  def new
    @source = AuditLogSource.new
    load_topics
  end

  def edit
    load_topics
  end

  def create
    @source = AuditLogSource.new(source_params)

    if @source.save
      redirect_to audit_log_source_path(@source), notice: "Audit log source '#{@source.name}' created."
    else
      load_topics
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @source.update(source_params)
      redirect_to audit_log_source_path(@source), notice: "Audit log source '#{@source.name}' updated."
    else
      load_topics
      render :edit, status: :unprocessable_content
    end
  end

  # Entries are never deleted, so a source that has any cannot go; disabling retires it.
  def destroy
    name = @source.name
    if @source.destroy
      redirect_to audit_log_sources_path, notice: "Audit log source '#{name}' deleted."
    else
      redirect_to audit_log_source_path(@source),
                  alert: "Cannot delete '#{name}': it has log entries, which are kept. Disable it instead."
    end
  end

  def toggle
    @source.update!(enabled: !@source.enabled)
    redirect_to audit_log_sources_path,
                notice: "Audit log source '#{@source.name}' #{@source.enabled? ? 'enabled' : 'disabled'}."
  end

  def run
    if @source.enabled?
      AuditLogs::RunSourceJob.perform_later(@source.id)
      redirect_to audit_log_source_path(@source), notice: 'Run queued.'
    else
      redirect_to audit_log_source_path(@source), alert: 'Enable the source before running it.'
    end
  end

  # Runs the program and shows what it would store, without storing anything.
  def preview
    result = AuditLogs::ScriptRunner.call(@source, since: @source.last_entry_at, timeout: PREVIEW_TIMEOUT)
    @result = result
    @parsed = AuditLogs::OutputParser.call(result.stdout)
    @already_stored = @source.audit_log_entries.where(fingerprint: @parsed.pluck(:fingerprint)).pluck(:fingerprint)
  rescue SystemCallError => e
    redirect_to audit_log_source_path(@source), alert: "Could not run #{@source.script_path}: #{e.message}"
  end

  private

  def set_source
    @source = AuditLogSource.find(params[:id])
  end

  def load_topics
    @training_topics = TrainingTopic.order(:name)
  end

  def source_params
    params.expect(audit_log_source: %i[name description script_path script_arguments environment_variables
                                       run_interval enabled training_topic_id])
  end
end
