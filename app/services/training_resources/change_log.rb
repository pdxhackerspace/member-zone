module TrainingResources
  # One row per edit to a topic's links or documents. Nothing is written while the
  # digest reminder is off, so turning it on later does not announce a backlog.
  class ChangeLog
    def self.link_added(link)
      record!(topic: link.training_topic, kind: 'link_added', title: link.title, resource: link,
              details: { 'url' => link.url })
    end

    def self.link_updated(link)
      return unless link.saved_change_to_title? || link.saved_change_to_url?

      details = {}
      details['title'] = link.saved_change_to_title if link.saved_change_to_title?
      details['url'] = link.saved_change_to_url if link.saved_change_to_url?
      record!(topic: link.training_topic, kind: 'link_updated', title: link.title, resource: link, details: details)
    end

    def self.link_removed(link)
      record!(topic: link.training_topic, kind: 'link_removed', title: link.title, resource: link,
              details: { 'url' => link.url })
    end

    def self.link_content_changed(link, details:, occurred_at:)
      record!(topic: link.training_topic, kind: 'link_content_changed', title: link.title, resource: link,
              details: details, occurred_at: occurred_at)
    end

    def self.document_added(document, topic)
      record!(topic: topic, kind: 'document_added', title: document.title, resource: document,
              details: file_snapshot(document))
    end

    def self.document_updated(document, topic, edit)
      details = {}
      details['title'] = edit[:title] if edit[:title]
      details['file'] = edit[:file] if edit[:file]
      record!(topic: topic, kind: 'document_updated', title: document.title, resource: document, details: details)
    end

    def self.document_removed(document, topic)
      record!(topic: topic, kind: 'document_removed', title: document.title, resource: document,
              details: file_snapshot(document))
    end

    def self.record!(**change)
      return unless ReminderSetting.enabled?(REMINDER_KEY)
      return if change[:topic].blank?

      resource = change[:resource]
      TrainingResourceChange.create!(
        training_topic: change[:topic],
        resource_type: resource&.class&.name,
        resource_id: resource&.id,
        kind: change[:kind],
        title: change[:title].to_s.truncate(255),
        details: change.fetch(:details, {}),
        actor: Current.actor,
        occurred_at: change.fetch(:occurred_at, Time.current)
      )
    end

    def self.file_snapshot(document)
      return {} unless document.file.attached?

      { 'filename' => document.file.filename.to_s, 'byte_size' => document.file.byte_size }
    end
  end
end
