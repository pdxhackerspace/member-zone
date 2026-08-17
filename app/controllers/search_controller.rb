class SearchController < AuthenticatedController
  def index
    @q = params[:q].to_s.strip
    return if @q.blank?

    # A member searches the roster they can already see; search.admin adds the source
    # records — Authentik, Slack, the sheet — behind it.
    if current_user_admin? || can?(:'search.admin')
      @admin_search = true
      search_admin
    else
      @admin_search = false
      search_member
    end
  end

  private

  # Encrypted email columns cannot be matched by substring the way names are, so each
  # search widens its name match with an exact lookup of the whole address typed.
  def search_admin
    pattern = "%#{@q.downcase}%"

    # search.admin widens the search to the source records; it does not confer the right to
    # read a profile, so the member list stays scoped the way it is everywhere else.
    @users = members_visible_to_viewer(
      User.where(
        "LOWER(COALESCE(full_name, '')) LIKE :p " \
        'OR LOWER(authentik_id) LIKE :p',
        p: pattern
      ).or(User.by_any_email(@q))
    ).order(:full_name).limit(25)
    @authentik_users = AuthentikUser.where(
      "LOWER(COALESCE(full_name, '')) LIKE :p " \
      "OR LOWER(COALESCE(username, '')) LIKE :p " \
      'OR LOWER(authentik_id) LIKE :p',
      p: pattern
    ).or(AuthentikUser.by_email(@q)).order(:full_name).limit(25)
    @sheet_entries = SheetEntry.where(
      "LOWER(COALESCE(name, '')) LIKE :p",
      p: pattern
    ).or(SheetEntry.by_email(@q)).order(:name).limit(25)
    @slack_users = SlackUser.where(
      "LOWER(COALESCE(display_name, '')) LIKE :p " \
      "OR LOWER(COALESCE(real_name, '')) LIKE :p " \
      "OR LOWER(COALESCE(username, '')) LIKE :p",
      p: pattern
    ).or(SlackUser.by_email(@q)).order(:display_name).limit(25)
    @paypal_payments = PaypalPayment.where(
      "LOWER(COALESCE(payer_name, '')) LIKE :p " \
      'OR LOWER(paypal_id) LIKE :p',
      p: pattern
    ).or(PaypalPayment.by_payer_email(@q)).order(transaction_time: :desc).limit(25)
    @recharge_payments = RechargePayment.where(
      "LOWER(COALESCE(customer_name, '')) LIKE :p " \
      'OR LOWER(recharge_id) LIKE :p',
      p: pattern
    ).or(RechargePayment.by_customer_email(@q)).order(processed_at: :desc).limit(25)
    @kofi_payments = KofiPayment.where(
      "LOWER(COALESCE(from_name, '')) LIKE :p " \
      'OR LOWER(kofi_transaction_id) LIKE :p',
      p: pattern
    ).or(KofiPayment.by_email(@q)).order(timestamp: :desc).limit(25)
  end

  def search_member
    pattern = "%#{@q.downcase}%"

    @matching_members = matching_member_profiles(pattern)
    @interest_matches = matching_interest_groups(pattern)
    @training_matches = matching_training_groups(pattern)
  end

  def matching_member_profiles(pattern)
    members_visible_to_viewer(
      User.where(
        "LOWER(COALESCE(full_name, '')) LIKE :p OR LOWER(COALESCE(username, '')) LIKE :p",
        p: pattern
      )
    ).order(:full_name).limit(25)
  end

  # Matching interests → the members who hold that interest and may be shown.
  def matching_interest_groups(pattern)
    Interest.where('LOWER(name) LIKE ?', pattern).alphabetical.filter_map do |interest|
      members = members_visible_to_viewer(interest.users).order(:full_name)
      next if members.empty?

      { interest: interest, members: members }
    end
  end

  # Matching training topics → the trained members and trainers who may be shown.
  def matching_training_groups(pattern)
    TrainingTopic.where('LOWER(name) LIKE ?', pattern).order(:name).filter_map do |topic|
      trained = members_visible_to_viewer(
        User.joins(:trainings_as_trainee).where(trainings: { training_topic_id: topic.id })
      ).distinct.order(:full_name)
      trainers = members_visible_to_viewer(topic.trainers).order(:full_name)
      next if trained.empty? && trainers.empty?

      { topic: topic, trained: trained, trainers: trainers }
    end
  end
end
