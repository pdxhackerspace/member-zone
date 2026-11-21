module TrainingResources
  # Lines present in the new copy of a page and absent from the copy we already
  # confirmed. The digest quotes a few of them so the email says what changed.
  class PageExcerpt
    LIMIT = 3
    LENGTH = 140

    def self.added(old_text, new_text)
      previous = lines(old_text).to_set
      added = lines(new_text).reject { |line| previous.include?(line) }
      [added.size, added.first(LIMIT).map { |line| line.truncate(LENGTH) }]
    end

    def self.lines(text)
      text.to_s.split("\n").map(&:strip).reject(&:empty?)
    end
  end
end
