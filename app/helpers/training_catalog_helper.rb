module TrainingCatalogHelper
  # Admins and catalog view-all holders link every topic (@linked_topic_ids is nil).
  # Everyone else links a topic they can request, already hold, or are allowed to open.
  def training_catalog_topic_linked?(topic)
    @linked_topic_ids.nil? || @linked_topic_ids.include?(topic.id)
  end

  # One step of indent per ancestor, capped so a deep tree cannot shove the name
  # off a narrow table.
  # Links a trained member or trainer when the viewer may open their profile.
  def training_roster_name(member, roster)
    css = 'text-decoration-none'
    css += ' text-secondary' unless member.active?
    return link_to(member.display_name, user_path(member), class: css) if roster.profile_linked?(member)

    tag.span(member.display_name, class: ('text-secondary' unless member.active?))
  end

  def training_catalog_nest_class(topic, depth)
    return if topic.parent_id.blank?

    level = depth.clamp(1, 4)
    "topic-nest-#{level}"
  end
end
