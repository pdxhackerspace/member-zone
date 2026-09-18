class MailLogController < AuthenticatedController
  PER_PAGE = 50

  before_action -> { require_privilege!(:'mail_log.view') }
  before_action :set_log_entry, only: :show

  def index
    @state = params[:state].presence_in(MailLogEntry::STATE_FILTERS.keys)
    @search = params[:q].to_s.strip
    @filter_counts = MailLogEntry.state_filter_counts(search: @search)
    @failed_in_queue_count = QueuedMail.failed.count
    @pagy, @log_entries = pagy(filtered_entries, limit: PER_PAGE)
  end

  def show; end

  private

  def filtered_entries
    scope = MailLogEntry.newest_first.includes(queued_mail: :recipient, actor: [])
    scope = scope.matching(@search) if @search.present?
    scope = scope.for_state(@state) if @state
    scope
  end

  def set_log_entry
    @log_entry = MailLogEntry.includes(queued_mail: :recipient, actor: []).find(params[:id])
  end
end
