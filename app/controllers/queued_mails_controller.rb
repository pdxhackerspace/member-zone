class QueuedMailsController < AuthenticatedController
  HTML_BLOCK_TAGS = %w[p div h1 h2 h3 h4 h5 h6 li tr].freeze
  HTML_LINK_URL_TAGS = %w[p li].freeze
  HTML_SPACED_TAGS = %w[td th].freeze

  before_action -> { require_privilege!(:'queued_mail.view') }, only: %i[index show]
  before_action -> { require_privilege!(:'queued_mail.approve') }, only: %i[approve reject]
  before_action -> { require_privilege!(:'queued_mail.edit') }, only: %i[edit update]
  before_action -> { require_privilege!(:'email_templates.ai_rewrite') }, only: :rewrite_with_ai
  # approve_all and reject_all act on the whole pending queue in one click, which is a very
  # different scale from reviewing a message, and nothing in the catalog distinguishes them.
  # retry_delivery and regenerate have no key at all.
  before_action :require_admin!, only: %i[approve_all reject_all retry_delivery regenerate]

  before_action :set_queued_mail, only: %i[show edit update approve reject regenerate retry_delivery rewrite_with_ai]

  def index
    @filter = params[:filter].presence || 'pending'
    @queued_mails = case @filter
                    when 'approved' then QueuedMail.approved
                    when 'rejected' then QueuedMail.rejected
                    when 'all'      then QueuedMail.all
                    else QueuedMail.pending
                    end
    @queued_mails = @queued_mails.newest_first.includes(:recipient, :email_template, :reviewed_by)
    @pending_count = QueuedMail.pending.count
  end

  def show; end

  def edit
    return if @queued_mail.pending?

    redirect_to queued_mail_path(@queued_mail),
                alert: 'Only pending messages can be edited.'
  end

  def update
    unless @queued_mail.pending?
      redirect_to queued_mail_path(@queued_mail), alert: 'Only pending messages can be edited.'
      return
    end

    if @queued_mail.update(queued_mail_update_params)
      @queued_mail.log_edit!(current_user)
      redirect_to queued_mail_path(@queued_mail), notice: 'Message updated.'
    else
      render :edit, status: :unprocessable_content
    end
  end

  def approve
    unless @queued_mail.pending?
      redirect_to queued_mail_path(@queued_mail), alert: 'This message has already been reviewed.'
      return
    end

    unless helpers.smtp_configured?
      redirect_to queued_mail_path(@queued_mail), alert: 'Cannot send email: SMTP is not configured.'
      return
    end

    @queued_mail.approve!(current_user)
    if @queued_mail.rejected?
      redirect_to queued_mail_path(@queued_mail),
                  alert: @queued_mail.approval_blocked_alert
      return
    end

    redirect_to queued_mails_path, notice: "Message to #{@queued_mail.to} has been approved and sent."
  end

  def reject
    unless @queued_mail.pending?
      redirect_to queued_mail_path(@queued_mail), alert: 'This message has already been reviewed.'
      return
    end

    @queued_mail.reject!(current_user)
    redirect_to queued_mails_path, notice: "Message to #{@queued_mail.to} has been rejected."
  end

  def retry_delivery
    unless @queued_mail.delivery_failed?
      redirect_to queued_mail_path(@queued_mail), alert: 'Only failed messages can be retried.'
      return
    end

    unless helpers.smtp_configured?
      redirect_to queued_mail_path(@queued_mail), alert: 'Cannot send email: SMTP is not configured.'
      return
    end

    @queued_mail.retry_delivery!
    redirect_to queued_mail_path(@queued_mail), notice: "Retrying delivery to #{@queued_mail.to}..."
  end

  def approve_all
    unless helpers.smtp_configured?
      redirect_to queued_mails_path, alert: 'Cannot send email: SMTP is not configured.'
      return
    end

    pending = QueuedMail.pending
    counts = QueuedMail.approve_all!(pending, current_user)
    notice = "Approved and sent #{counts[:approved]} message#{'s' if counts[:approved] != 1}."
    extras = QueuedMail.approve_all_notice_extras(counts)
    notice += " #{extras}" if extras.present?
    redirect_to queued_mails_path, notice: notice
  end

  def reject_all
    pending = QueuedMail.pending
    count = pending.count
    pending.find_each { |qm| qm.reject!(current_user) }
    redirect_to queued_mails_path, notice: "Rejected #{count} message#{'s' if count != 1}."
  end

  def regenerate
    unless @queued_mail.pending?
      redirect_to queued_mail_path(@queued_mail), alert: 'Only pending messages can be regenerated.'
      return
    end

    unless @queued_mail.can_regenerate?
      redirect_to queued_mail_path(@queued_mail),
                  alert: 'This message cannot be regenerated (no template or recipient).'
      return
    end

    @queued_mail.regenerate!(actor: current_user)
    redirect_to queued_mail_path(@queued_mail), notice: 'Message regenerated from template.'
  end

  def rewrite_with_ai
    unless @queued_mail.pending?
      render json: { error: 'Only pending messages can be rewritten.' }, status: :unprocessable_content
      return
    end

    attrs = rewrite_params
    result = QueuedMails::RewriteWithAi.call(
      queued_mail: @queued_mail,
      subject: attrs[:subject],
      body_html: attrs[:body_html],
      body_text: attrs[:body_text]
    )

    if result.success?
      render json: {
        body_html: result.body_html,
        body_text: result.body_text,
        message: result.message
      }
    else
      render json: { error: result.message }, status: :unprocessable_content
    end
  end

  private

  def set_queued_mail
    @queued_mail = QueuedMail.find(params[:id])
  end

  def queued_mail_params
    params.expect(queued_mail: %i[to subject body_html body_text])
  end

  def queued_mail_update_params
    attrs = queued_mail_params.to_h
    attrs['body_text'] = html_to_plain_text(attrs['body_html']) if sync_body_text?
    attrs
  end

  def sync_body_text?
    params[:sync_body_text].present?
  end

  def html_to_plain_text(html)
    fragment = Nokogiri::HTML.fragment(html.to_s)
    node_to_plain_text(fragment)
      .gsub("\u00a0", ' ')
      .gsub(/[ \t]+\n/, "\n")
      .gsub(/\n[ \t]+/, "\n")
      .gsub(/\n{3,}/, "\n\n")
      .strip
  end

  def node_to_plain_text(node)
    return node.text if node.text?
    return "\n" if node.element? && node.name == 'br'

    text = node.children.map { |child| node_to_plain_text(child) }.join
    if append_link_urls?(node)
      urls = node.css('a[href]').filter_map { |link| link['href'].presence }
      text = append_link_urls(text, urls)
    end
    text += "\n" if node.element? && HTML_BLOCK_TAGS.include?(node.name)
    text += ' ' if node.element? && HTML_SPACED_TAGS.include?(node.name)
    text
  end

  def append_link_urls?(node)
    node.element? && HTML_LINK_URL_TAGS.include?(node.name) && node.css('a[href]').any?
  end

  def append_link_urls(text, urls)
    return text if urls.blank?

    [text.rstrip, '', *urls, ''].join("\n")
  end

  def rewrite_params
    params.expect(rewrite: %i[subject body_html body_text])
  end
end
