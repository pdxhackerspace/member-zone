module TrainingResources
  # Turns a burst of edits to one resource into the lines a digest should show.
  # Adding something and then removing it before the digest goes out is silence.
  class ChangeCollapser
    Entry = Struct.new(:change, :source_ids, keyword_init: true)

    def self.entries(changes)
      new(changes).entries
    end

    def initialize(changes)
      @changes = changes
    end

    def entries
      @changes.group_by { |change| group_key(change) }.flat_map { |_, group| collapse(group) }
    end

    private

    def group_key(change)
      [change.training_topic_id, change.resource_type.to_s, change.resource_id]
    end

    def collapse(group)
      ordered = group.sort_by { |change| [change.occurred_at, change.id.to_i] }
      ids = ordered.map(&:id)
      added = ordered.find { |change| change.kind.end_with?('_added') }
      removed = ordered.rfind { |change| change.kind.end_with?('_removed') }
      return removed_result(added, removed, ids) if removed && (added.nil? || removed.occurred_at >= added.occurred_at)
      return [entry(refreshed_add(added, ordered), ids)] if added

      edit_entries(ordered, ids)
    end

    def removed_result(added, removed, ids)
      return [] if added

      [entry(removed, ids)]
    end

    def edit_entries(ordered, ids)
      content = ordered.rfind { |change| change.kind == 'link_content_changed' }
      meta = ordered.rfind { |change| change.kind.end_with?('_updated') }
      [meta, content].compact.uniq.map { |change| entry(change, ids) }
    end

    def refreshed_add(added, ordered)
      copy = added.dup
      copy.title = ordered.last.title.presence || added.title
      copy.details = merged_details(added, ordered)
      copy
    end

    def merged_details(added, ordered)
      details = added.details.deep_dup
      content = ordered.rfind { |change| change.kind == 'link_content_changed' }
      return details unless content

      details.merge(
        'added_line_count' => content.details['added_line_count'],
        'excerpts' => content.details['excerpts'],
        'changed_on' => content.details['changed_on']
      )
    end

    def entry(change, ids)
      Entry.new(change: change, source_ids: ids)
    end
  end
end
