module TrainingCatalogHelper
  # Admins and catalog view-all holders link every topic (@linked_topic_ids is nil).
  # Everyone else links a topic they can request, already hold, or are allowed to open.
  def training_catalog_topic_linked?(topic)
    @linked_topic_ids.nil? || @linked_topic_ids.include?(topic.id)
  end

  # One step of indent per ancestor, capped so a deep tree cannot shove the name
  # off a narrow table.
  def training_catalog_nest_class(topic, depth)
    return if topic.parent_id.blank?

    level = depth.clamp(1, 4)
    "topic-nest-#{level}"
  end
end
