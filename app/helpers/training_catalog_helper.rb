module TrainingCatalogHelper
  # Admins and catalog view-all holders link every topic (@linked_topic_ids is nil).
  # Everyone else links a topic they can request, already hold, or are allowed to open.
  def training_catalog_topic_linked?(topic)
    @linked_topic_ids.nil? || @linked_topic_ids.include?(topic.id)
  end

  # Names only when the topic shows them on the row. Otherwise the sentence stays
  # generic, so contacting a hidden list does not publish who is trained.
  def training_contact_detail(members)
    names = Array(members).map(&:display_name)
    return 'This goes to the members trained in this topic. They can reply to you.' if names.empty?

    "This goes to #{names.to_sentence}. They can reply to you."
  end

  # People named in the catalog's Contact message. Hidden when the topic has not
  # agreed to show who is trained, including for an admin or an area steward.
  def names_for_catalog_contact(topic)
    return [] unless topic.trained_members_visible?

    Array(@roster_members[topic.id]).reject { |member| member.id == current_user.id }
  end

  # Links a trained member or trainer when the viewer may open their profile.
  def training_roster_name(member, roster)
    css = 'text-decoration-none'
    css += ' text-secondary' unless member.active?
    return link_to(member.display_name, user_path(member), class: css) if roster.profile_linked?(member)

    tag.span(member.display_name, class: ('text-secondary' unless member.active?))
  end

  # One step of indent per ancestor, capped so a deep tree cannot shove the name
  # off a narrow table.
  def training_catalog_nest_class(topic, depth)
    return if topic.parent_id.blank?

    level = depth.clamp(1, 4)
    "topic-nest-#{level}"
  end
end
