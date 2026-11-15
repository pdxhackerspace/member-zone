class MessagesController < AuthenticatedController
  include TrainingHistoryData

  before_action :prepare_member_navigation, only: :index
  before_action :load_message, only: %i[show destroy mark_unread restore]

  rescue_from ActiveRecord::RecordNotFound, with: :message_not_found

  def index
    @folder = sanitized_folder(params[:folder])
    @pagy, @messages = pagy(
      Message.folder(current_user, @folder).includes(:sender, :recipient).newest_first,
      limit: 20
    )
  end

  def show
    if current_user.id == @message.recipient_id && @message.unread? && !@message.deleted_by?(current_user)
      @message.read!
    end
    @return_folder = sanitized_folder(params[:folder])
    prepare_member_navigation
  end

  def create
    if params[:in_reply_to_id].present?
      create_reply
    else
      create_new
    end
  end

  def destroy
    @message.delete_for(current_user)
    folder = sanitized_folder(params[:return_folder])
    redirect_to messages_path(folder: folder), notice: 'Message moved to trash.'
  end

  def mark_unread
    unless current_user.id == @message.recipient_id
      redirect_to message_path(@message), alert: 'Only the recipient can mark a message unread.'
      return
    end

    @message.unread!
    redirect_to messages_path(folder: :unread), notice: 'Message marked as unread.'
  end

  def restore
    unless @message.in_trash_for?(current_user)
      redirect_to messages_path(folder: :trash), alert: 'Message cannot be restored.'
      return
    end

    @message.restore_for(current_user)
    redirect_to messages_path(folder: :all), notice: 'Message restored from trash.'
  end

  private

  def prepare_member_navigation
    @active_tab = :messages
    @user = @home_user = current_user
    @home_payments_count = @payments_count = PaymentHistory.for_user(current_user).count
    @home_parking_notices_count = @parking_notices_count = current_user.parking_notices.not_cleared.count
    @home_unread_messages_count = @unread_messages_count =
      current_user.received_messages.not_deleted_by_recipient.unread.count
    load_completed_training_requests(current_user)
  end

  def load_message
    scope = Message.visible_to(current_user).or(Message.trash_for(current_user))
    @message = scope.find(params[:id])
  end

  def message_not_found
    redirect_to messages_path, alert: 'Message not found.'
  end

  def sanitized_folder(value)
    symbol = value&.to_sym
    Message::FOLDERS.include?(symbol) ? symbol : :unread
  end

  def create_new
    unless current_user_admin?
      redirect_to messages_path, alert: 'You are not authorized to send messages.'
      return
    end

    recipient = User.find(params[:recipient_id])
    message = current_user.sent_messages.build(
      recipient: recipient,
      subject: params[:subject],
      body: params[:body]
    )

    if message.save
      MemberMailer.message_received(message).deliver_later
      redirect_to user_path(recipient, tab: :messages), notice: 'Message sent.'
    else
      redirect_to user_path(recipient, tab: :messages),
                  alert: "Failed to send message: #{message.errors.full_messages.join(', ')}"
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to users_path, alert: 'Recipient not found.'
  end

  def create_reply
    original = Message.find(params[:in_reply_to_id])
    unless original.recipient_id == current_user.id
      redirect_to messages_path, alert: 'You can only reply to messages addressed to you.'
      return
    end

    message = current_user.sent_messages.build(
      recipient: original.sender,
      subject: params[:subject],
      body: params[:body]
    )

    if message.save
      MemberMailer.message_received(message).deliver_later
      redirect_to messages_path(folder: :sent), notice: 'Reply sent.'
    else
      redirect_to message_path(original),
                  alert: "Failed to send reply: #{message.errors.full_messages.join(', ')}"
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to messages_path, alert: 'Original message not found.'
  end
end
