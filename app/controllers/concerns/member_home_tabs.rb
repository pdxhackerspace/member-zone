module MemberHomeTabs
  include ParkingStatusFiltering

  private

  def prepare_member_home_tabs_data
    set_member_dashboard_data
    set_self_service_training_data
    set_home_parking_data
    set_home_messages_data
    set_home_payments_data
  end

  def set_home_parking_data
    base = @home_user.parking_notices
    @home_parking_notices_count = base.not_cleared.count
    @parking_status_counts = base.group(:status).count
    @parking_selected_statuses = selected_parking_statuses
    @home_parking_notices_list = apply_parking_status_filter(base).newest_first.limit(50)
  end

  def set_home_messages_data
    base = @home_user.received_messages.not_deleted_by_recipient
    @home_messages_count = base.count
    @home_unread_messages_count = base.unread.count
  end

  def set_home_payments_data
    payments_query = PaymentHistory.for_user(@home_user, event_type: params[:event_type].presence)
    @home_payments_count = payments_query.count

    return unless @active_tab == :payments

    @pagy_payments, @home_payments = pagy(payments_query, limit: 20, page_key: 'payments_page')
  end

  def set_self_service_training_data
    @member_requestable_topics = TrainingTopic.available_for_member_requests

    @trainer_training_requests_by_topic = TrainingRequest.for_trainer_dashboard(@home_user)
                                                         .group_by(&:training_topic)
  end

  def set_member_dashboard_data
    items = MemberDashboardBuilder.new(
      user: @home_user,
      due_soon_days: MembershipSetting.manual_payment_due_soon_days,
      path_for_tab: ->(tab) { root_path(tab: tab) }
    ).build

    @member_dashboard_attention_items = items[:attention_items]
    @member_dashboard_ok_items = items[:ok_items]
  end
end
