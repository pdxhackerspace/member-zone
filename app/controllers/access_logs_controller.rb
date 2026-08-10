class AccessLogsController < AuthenticatedController
  PER_PAGE = 200

  before_action -> { require_privilege!(:'access.view_logs') }, only: :index
  before_action -> { require_privilege!(:'access.import_logs') }, only: %i[upload import]
  before_action -> { require_privilege!(:'access.link_logs') }, only: :link_user
  # create_member makes a member record out of an unmatched badge scan. That is member
  # creation wearing an access-log hat, and members.create does not appear on this page.
  before_action :require_admin!, only: :create_member

  def index
    base_logs = AccessLog.includes(:user).recent

    # Calculate counts before filtering
    @total_count = base_logs.count
    @linked_count = base_logs.where.not(user_id: nil).count
    @unlinked_count = base_logs.where(user_id: nil).where.not(name: [nil, '']).count
    @no_name_count = base_logs.where(user_id: nil, name: [nil, '']).count
    @service_account_count = base_logs.joins(:user).where(users: { service_account: true }).count

    @access_logs = base_logs

    # Apply linked/unlinked filter
    case params[:linked]
    when 'yes'
      @access_logs = @access_logs.where.not(user_id: nil)
    when 'no'
      @access_logs = @access_logs.where(user_id: nil).where.not(name: [nil, ''])
    when 'no_name'
      @access_logs = @access_logs.where(user_id: nil, name: [nil, ''])
    when 'service'
      @access_logs = @access_logs.joins(:user).where(users: { service_account: true })
    end

    @filter_active = params[:linked].present?

    # Apply search filter if provided
    if params[:q].present?
      search_term = "%#{params[:q]}%"
      @access_logs = @access_logs.where(
        'name ILIKE ? OR location ILIKE ? OR raw_text ILIKE ?',
        search_term, search_term, search_term
      )
    end

    # Pagination
    @page = (params[:page] || 1).to_i
    @page = 1 if @page < 1
    @display_count = @access_logs.count
    @total_pages = (@display_count.to_f / PER_PAGE).ceil
    @access_logs = @access_logs.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)

    # Load users for the link modal (only if there are unlinked entries)
    @all_users = User.ordered_by_display_name if @unlinked_count.positive?
  end

  def upload
    file = params[:log_file]

    if file.blank?
      redirect_to access_logs_path, alert: 'Please select a log file to upload.'
      return
    end

    lines        = file.read.force_encoding('UTF-8').scrub.lines
    imported     = 0
    skipped      = 0
    duplicate    = 0
    error        = 0
    file_year    = Time.current.year

    lines.each do |line|
      line = line.chomp
      next if line.blank?

      begin
        parser = AccessLogParser.new(line, file_year: file_year)

        if parser.should_skip?
          skipped += 1
          next
        end

        parsed = parser.parse

        raw = parsed ? parsed[:raw_text] : line
        ts  = parsed ? parsed[:logged_at] : nil

        if AccessLog.exists?(raw_text: raw, logged_at: ts)
          duplicate += 1
          next
        end

        parser.create_access_log!
        imported += 1
      rescue StandardError => e
        Rails.logger.warn("Access log upload: error on line: #{e.message}")
        error += 1
      end
    end

    parts = ["#{imported} #{'entry'.pluralize(imported)} imported"]
    parts << "#{duplicate} duplicate#{'s' if duplicate != 1} skipped" if duplicate.positive?
    parts << "#{skipped} system message#{'s' if skipped != 1} skipped" if skipped.positive?
    parts << "#{error} error#{'s' if error != 1}" if error.positive?

    redirect_to access_logs_path, notice: "#{parts.join(', ')}."
  end

  def link_user
    @log = AccessLog.find(params[:id])
    user = User.find(params[:user_id])

    @log.update!(user: user)

    # Add the access log name as an alias if it differs from the user's full_name
    user.add_alias!(@log.name) if @log.name.present?

    # Also link other unlinked access log entries with the same name
    linked_count = 0
    if @log.name.present?
      linked_count = AccessLog.where(user_id: nil, name: @log.name)
                              .update_all(user_id: user.id)
    end

    extra = if linked_count.positive?
              " Also linked #{linked_count} other " \
                "#{'entry'.pluralize(linked_count)} with the same name."
            else
              ''
            end
    redirect_to access_logs_path(linked: params[:linked], q: params[:q], page: params[:page]),
                notice: "Linked '#{@log.name}' to #{user.display_name}.#{extra}"
  end

  def create_member
    @log = AccessLog.find(params[:id])

    if @log.user_id.present?
      redirect_to access_logs_path, alert: 'This access log entry is already linked to a member.'
      return
    end

    # Create a new user from the access log name
    user = User.new(
      full_name: @log.name,
      membership_state: User.initial_membership_state,
      payment_type: 'unknown'
    )

    if user.save
      @log.update!(user: user)

      # Also link other unlinked access log entries with the same name
      linked_count = 0
      if @log.name.present?
        linked_count = AccessLog.where(user_id: nil, name: @log.name)
                                .update_all(user_id: user.id)
      end

      extra = linked_count.positive? ? " Also linked #{linked_count} other #{'entry'.pluralize(linked_count)}." : ''
      redirect_to user_path(user), notice: "Created member '#{user.display_name}' from access log.#{extra}"
    else
      redirect_to access_logs_path(linked: params[:linked], q: params[:q], page: params[:page]),
                  alert: "Failed to create member: #{user.errors.full_messages.join(', ')}"
    end
  end

  def import
    AccessLogsImportJob.perform_later
    redirect_to access_logs_path, notice: 'Access log import started.'
  end
end
