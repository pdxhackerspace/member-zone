module TrainingResources
  # The HTML and plain-text lists a digest email inserts. Titles, URLs, and
  # excerpts all come from curators or from the pages we fetched, so they are escaped.
  class DigestPresenter
    def initialize(entries)
      @entries = entries
    end

    def count_phrase
      count = @entries.size
      verb = count == 1 ? 'is' : 'are'
      "#{verb} #{count} #{'update'.pluralize(count)}"
    end

    def topic_names
      @entries.map { |entry| entry.change.training_topic.name }.uniq.to_sentence
    end

    def html
      grouped.map { |topic, entries| html_section(topic, entries) }.join
    end

    def text
      grouped.map { |topic, entries| text_section(topic, entries) }.join("\n")
    end

    private

    def grouped
      @entries.sort_by { |entry| [entry.change.training_topic.name.to_s, entry.change.occurred_at] }
              .group_by { |entry| entry.change.training_topic.name }
    end

    def html_section(topic, entries)
      items = entries.map { |entry| "<li>#{escape(line_for(entry.change))}</li>" }.join
      "<p><strong>#{escape(topic)}</strong></p><ul>#{items}</ul>"
    end

    def text_section(topic, entries)
      lines = entries.map { |entry| "- #{line_for(entry.change)}" }
      "#{topic}\n#{lines.join("\n")}\n"
    end

    def line_for(change)
      case change.kind
      when 'link_added' then with_content("New link: #{change.title} (#{change.details['url']})", change)
      when 'link_updated' then link_updated(change)
      when 'link_removed' then "Link removed: #{change.title}"
      when 'link_content_changed' then content_line("Link content changed: #{change.title}", change)
      when 'document_added' then document_added(change)
      when 'document_updated' then document_updated(change)
      when 'document_removed' then "Document removed: #{change.title}"
      else change.title
      end
    end

    def link_updated(change)
      parts = ["Link updated: #{change.title}"]
      urls = change.details['url']
      titles = change.details['title']
      parts << "now #{urls.last}" if urls.is_a?(Array)
      parts << "renamed from #{titles.first}" if titles.is_a?(Array)
      parts.join(', ')
    end

    def document_added(change)
      "New document: #{change.title} (#{file_phrase(change.details)}), added #{on_date(change.occurred_at)}"
    end

    def document_updated(change)
      parts = ["Document updated: #{change.title}"]
      titles = change.details['title']
      file = change.details['file']
      parts << "renamed from #{titles.first}" if titles.is_a?(Array)
      parts << "file replaced (#{file.dig('to', 'filename')})" if file.is_a?(Hash) && file['to']
      parts.join(', ')
    end

    def with_content(line, change)
      return line if change.details['excerpts'].blank? && change.details['added_line_count'].to_i.zero?

      "#{line}. #{content_clause(change)}"
    end

    def content_line(line, change)
      date = on_date(change.details['changed_on']) || on_date(change.occurred_at)
      "#{line}, #{date}. #{content_clause(change)}".strip
    end

    def content_clause(change)
      count = change.details['added_line_count'].to_i
      excerpts = Array(change.details['excerpts']).compact_blank.map { |excerpt| "\"#{excerpt}\"" }
      count_phrase = "#{count} #{'line'.pluralize(count)} added" if count.positive?
      [count_phrase, excerpts.join(' ')].compact_blank.join(' ')
    end

    def file_phrase(details)
      name = details['filename'].presence || 'file'
      size = details['byte_size']
      return name if size.blank?

      "#{name}, #{ActiveSupport::NumberHelper.number_to_human_size(size)}"
    end

    def on_date(value)
      time = value.is_a?(String) ? Time.zone.parse(value) : value
      return if time.blank?

      time.strftime("%b #{time.day}")
    rescue ArgumentError
      nil
    end

    def escape(text)
      ERB::Util.html_escape(text.to_s)
    end
  end
end
