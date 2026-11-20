module TrainingResources
  # Turns a fetched page into comparable lines. Binary responses stay nil so the
  # checker hashes the bytes instead of pretending a PDF is prose.
  class PageText
    def self.extract(body, content_type)
      new(body, content_type).extract
    end

    def initialize(body, content_type)
      @body = body.to_s
      @content_type = content_type.to_s.downcase
    end

    def extract
      return plain_lines if plain?
      return html_lines if html?

      nil
    end

    private

    def plain?
      @content_type.blank? || @content_type.include?('text/plain') || @content_type.include?('markdown')
    end

    def html?
      return true if @content_type.include?('html')

      stripped = @body.lstrip
      stripped.start_with?('<!DOCTYPE', '<!doctype', '<html', '<HTML')
    end

    def plain_lines
      normalize(@body).split(/\n+/).map { |line| line.gsub(/[ \t]+/, ' ').strip }.reject(&:empty?).join("\n")
    end

    def html_lines
      document = Nokogiri::HTML(normalize(@body))
      document.css('script, style, noscript, template, head').remove
      lines = document.css('h1, h2, h3, h4, h5, h6, p, li, td, th, blockquote, pre').filter_map do |node|
        node.text.gsub(/\s+/, ' ').strip.presence
      end
      lines = [document.at('body')&.text.to_s.gsub(/\s+/, ' ').strip].compact_blank if lines.empty?
      lines.join("\n")
    end

    def normalize(text)
      encoded = text.dup.force_encoding(Encoding::UTF_8)
      return encoded if encoded.valid_encoding?

      encoded.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end
  end
end
