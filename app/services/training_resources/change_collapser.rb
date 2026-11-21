module TrainingResources
  # Turns a burst of edits to one resource into the lines a digest should show.
  # Adding something and then removing it before anyone is told is silence.
  # Someone who was already told it existed still hears that it was removed.
  class ChangeCollapser
    Entry = Struct.new(:change, :source_ids, keyword_init: true)
    PAGE_DETAIL_KEYS = %w[added_line_count excerpts changed_on].freeze

    def self.entries(changes, announced_ids: [])
      new(changes, announced_ids).entries
    end

    def initialize(changes, announced_ids)
      @changes = changes
      @announced_ids = Array(announced_ids).to_set(&:to_i)
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
      added = ordered.rfind { |change| change.kind.end_with?('_added') }
      removed = ordered.rfind { |change| change.kind.end_with?('_removed') }
      return removed_result(added, removed, ordered, ids) if removal_latest?(removed, added)
      return [entry(refreshed_add(added, ordered), ids)] if added

      edit_entries(ordered, ids)
    end

    # The latest add and the latest removal decide. A resource that was removed and
    # then added again is present, so the digest shows the add.
    def removal_latest?(removed, added)
      return false unless removed
      return true unless added

      later?(removed, added)
    end

    def later?(candidate, other)
      return true if candidate.occurred_at > other.occurred_at

      candidate.occurred_at == other.occurred_at && candidate.id.to_i > other.id.to_i
    end

    def removed_result(added, removed, ordered, ids)
      return [] if added && !told_it_existed?(ordered, removed)

      [entry(removed, ids)]
    end

    def told_it_existed?(ordered, removed)
      ordered.any? { |change| announced?(change) && present_before?(change, removed) }
    end

    def present_before?(change, removed)
      !change.kind.end_with?('_removed') && !later?(change, removed)
    end

    def announced?(change)
      @announced_ids.include?(change.id.to_i)
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

    # Only edits after this add belong on the line. An earlier life of the same
    # resource, or a page excerpt from before a URL change, would be the wrong one.
    def merged_details(added, ordered)
      details = added.details.deep_dup
      ordered.each { |change| apply_later_details(details, change) if later?(change, added) }
      details
    end

    def apply_later_details(details, change)
      apply_link_update(details, change.details) if change.kind == 'link_updated'
      apply_document_update(details, change.details) if change.kind == 'document_updated'
      apply_content_change(details, change.details) if change.kind == 'link_content_changed'
    end

    def apply_link_update(details, change_details)
      url = change_details['url']
      return unless url.is_a?(Array)

      details['url'] = url.last
      PAGE_DETAIL_KEYS.each { |key| details.delete(key) }
    end

    def apply_document_update(details, change_details)
      file = change_details['file']
      details.merge!(file['to']) if file.is_a?(Hash) && file['to'].is_a?(Hash)
    end

    def apply_content_change(details, change_details)
      details['added_line_count'] = change_details['added_line_count']
      details['excerpts'] = change_details['excerpts']
      details['changed_on'] = change_details['changed_on']
    end

    def entry(change, ids)
      Entry.new(change: change, source_ids: ids)
    end
  end
end
