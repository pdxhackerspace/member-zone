# The stacking filters on the member list. Each axis narrows the set independently, and a chip
# row counts against every axis but its own: once PayPal is picked, Cash still has to show how
# many members switching to it would find, not the zero it shares with PayPal.
module MemberListFiltering
  private

  # Applies every active filter axis to +scope+, skipping +except+ when given.
  def apply_member_filters(scope, except: nil)
    scope = apply_member_search(scope) unless except == :q
    scope = apply_member_column_filters(scope, except)
    scope = apply_member_plan_filter(scope) unless except == :membership_plan_id
    scope = scope.where(active: params[:active] == 'true') if params[:active].present? && except != :active
    scope = apply_member_account_filter(scope) unless except == :account_type
    scope = apply_member_missing_filter(scope) unless except == :missing
    scope = scope.non_service_accounts.where(key_access_paused: true) if params[:key_access] == 'paused' &&
                                                                         except != :key_access
    scope
  end

  # The members the list would show with one axis left out — what that axis's chips count.
  def members_without_filter(base, axis)
    apply_member_filters(base, except: axis).non_service_accounts
  end

  def apply_member_search(scope)
    return scope if params[:q].blank?

    # Encrypted email cannot be matched by substring; a whole address still resolves
    # through the lookup digest.
    scope.where(
      "LOWER(COALESCE(full_name, '')) LIKE :p " \
      'OR LOWER(authentik_id) LIKE :p ' \
      "OR LOWER(COALESCE(username, '')) LIKE :p",
      p: "%#{params[:q].downcase}%"
    ).or(scope.merge(User.by_any_email(params[:q])))
  end

  # Axes that are a plain equality match on a users column.
  def apply_member_column_filters(scope, except)
    %i[membership_state membership_status payment_type dues_status].each do |column|
      next if except == column || params[column].blank?

      scope = scope.non_service_accounts.where(column => params[column])
    end
    if params[:emergency_active_override] == '1' && except != :emergency_active_override
      scope = scope.non_service_accounts.where(emergency_active_override: true)
    end
    scope
  end

  def apply_member_plan_filter(scope)
    return scope if params[:membership_plan_id].blank?

    plan_id = params[:membership_plan_id] == 'none' ? nil : params[:membership_plan_id]
    scope.non_service_accounts.where(membership_plan_id: plan_id)
  end

  def apply_member_account_filter(scope)
    case params[:account_type]
    when 'service' then scope.service_accounts
    when 'member' then scope.non_service_accounts
    else scope
    end
  end

  def apply_member_missing_filter(scope)
    case params[:missing]
    when 'rfid' then scope.non_service_accounts.where.missing(:rfids)
    when 'email' then scope.non_service_accounts.where("email IS NULL OR email = ''")
    else scope
    end
  end
end
