module ReportsHelper
  # How a member's building access reads in a report row. Having neither a key nor the
  # training is the unremarkable case and stays muted; a key with no training behind it is
  # the one worth an admin's attention. When training exists, the date sits underneath in
  # the compact admin date format.
  def building_access_cell(status)
    status ||= Reports::BuildingAccessStatus::NONE
    label = building_access_label(status)

    if status.trained?
      safe_join([
                  tag.span(label, class: building_access_label_class(status)),
                  tag.div(admin_profile_time(status.trained_at), class: 'text-12 text-secondary')
                ])
    else
      tag.span(label, class: building_access_label_class(status))
    end
  end

  # How long a member has been waiting for their orientation. Most waits are short and stay
  # muted; once someone is over halfway to the point where an un-oriented member falls
  # inactive, the number is worth reading twice.
  def orientation_wait_cell(since)
    return tag.span('—', class: 'text-secondary') if since.blank?

    days = ((Time.current - since) / 1.day).floor
    halfway = MembershipSetting.new_member_expiry_days / 2
    css = days >= halfway ? 'fw-medium text-warning' : 'text-secondary'
    tag.span("#{days} #{'day'.pluralize(days)}", class: css)
  end

  private

  def building_access_label(status)
    if status.key? && status.trained?
      'Key + trained'
    elsif status.key?
      'Key, not trained'
    elsif status.trained?
      'Trained, no key'
    else
      'Neither'
    end
  end

  def building_access_label_class(status)
    if status.key? && !status.trained?
      'fw-medium text-warning'
    elsif status.any?
      'fw-medium'
    else
      'text-secondary'
    end
  end
end
