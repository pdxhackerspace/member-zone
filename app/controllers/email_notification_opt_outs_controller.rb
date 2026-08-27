class EmailNotificationOptOutsController < AdminController
  include Pagy::Method

  PER_PAGE = 50

  before_action :set_opt_out, only: :destroy

  def index
    @pagy, @opt_outs = pagy(EmailNotificationOptOut.ordered.includes([]), limit: PER_PAGE)
    @email_filter = params[:email].to_s.strip
    return if @email_filter.blank?

    @pagy, @opt_outs = pagy(
      EmailNotificationOptOut.merge(EmailNotificationOptOut.by_email(@email_filter)).ordered,
      limit: PER_PAGE
    )
  end

  def destroy
    @opt_out.destroy!
    redirect_to email_notification_opt_outs_path, notice: 'Email opt-out removed.'
  end

  private

  def set_opt_out
    @opt_out = EmailNotificationOptOut.find(params[:id])
  end
end
