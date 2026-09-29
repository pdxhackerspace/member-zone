# The combined audit log: entries from every source the member may read, newest first.
# Entries can be read and explained here but never edited or deleted.
class AuditLogEntriesController < AuthenticatedController
  PER_PAGE = 50
  STATES = %w[unexplained alerted].freeze

  # Topic-scoped readers hold audit_logs.view for particular topics, so the gate asks whether
  # they hold it for any; which sources they may open is decided by AuditLogSource.readable_by.
  before_action -> { require_privilege!(:'audit_logs.view_all') unless can_for_any_topic?(:'audit_logs.view') }
  before_action :load_sources
  before_action :set_entry, only: %i[show explain]

  def index
    @source = @sources.find { |source| source.id.to_s == params[:source] }
    @state = params[:state] if STATES.include?(params[:state])
    @query = params[:q].to_s.strip
    @from = parse_date(params[:from])
    @to = parse_date(params[:to])

    scope = filtered_scope
    load_counts
    @pagy, @entries = pagy(scope.includes(:audit_log_source, :explained_by).newest_first, limit: PER_PAGE)
  end

  def show; end

  def explain
    @entry.explain!(params.expect(audit_log_entry: [:explanation])[:explanation], by: true_user)
    redirect_to audit_log_entry_path(@entry), notice: 'Explanation saved.'
  end

  private

  def load_sources
    @sources = AuditLogSource.readable_by(current_user).ordered.to_a
  end

  def set_entry
    @entry = AuditLogEntry.where(audit_log_source_id: @sources.map(&:id)).find(params[:id])
  end

  def visible_scope
    AuditLogEntry.where(audit_log_source_id: @sources.map(&:id))
  end

  def filtered_scope
    scope = visible_scope
    scope = scope.where(audit_log_source_id: @source.id) if @source
    scope = scope.unexplained if @state == 'unexplained'
    scope = scope.alerted if @state == 'alerted'
    scope = scope.matching(@query) if @query.present?
    scope = scope.where(occurred_at: @from.beginning_of_day..) if @from
    scope = scope.where(occurred_at: ..@to.end_of_day) if @to
    scope
  end

  # Pill counts describe the whole visible log, not the current page of results, so a pill
  # always says how much is behind it.
  def load_counts
    @total_count = visible_scope.count
    @source_counts = visible_scope.group(:audit_log_source_id).count
    @unexplained_count = visible_scope.unexplained.count
    @alerted_count = visible_scope.alerted.count
  end

  def parse_date(value)
    Date.iso8601(value.to_s) if value.present?
  rescue Date::Error
    nil
  end
end
