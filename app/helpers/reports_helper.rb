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
