module TrainingTopicLinksHelper
  def link_check_status(link)
    snapshot = link.content_snapshot
    return if snapshot.nil? || snapshot.checked_at.blank?

    tag.span(link_check_phrase(snapshot), class: "text-12 #{link_check_class(snapshot)}")
  end

  private

  def link_check_class(snapshot)
    snapshot.problem? ? 'text-warning' : 'text-secondary'
  end

  def link_check_phrase(snapshot)
    return snapshot.problem_phrase if snapshot.problem?
    return link_check_changed(snapshot) if snapshot.changed_at

    "Checked #{time_ago_in_words(snapshot.checked_at)} ago"
  end

  def link_check_changed(snapshot)
    changed = snapshot.changed_at.strftime("%b #{snapshot.changed_at.day}")
    "Changed #{changed} · checked #{time_ago_in_words(snapshot.checked_at)} ago"
  end
end
