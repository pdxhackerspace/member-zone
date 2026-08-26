module Emails
  class BannerPresenter
    FRAGMENT_KEY = 'outgoing_email_banner'

    ALLOWED_TAGS = %w[p br strong b em i u a ul ol li h1 h2 h3 h4 h5 h6 span div].freeze
    ALLOWED_ATTRIBUTES = %w[href target style].freeze

    def self.for_email
      content = TextFragment.content_for(FRAGMENT_KEY).to_s.strip
      return nil if content.blank?

      new(content)
    end

    def initialize(html_content)
      @html_content = html_content
    end

    def present?
      @html_content.present?
    end

    def html
      sanitize(@html_content)
    end

    def text
      Loofah.fragment(@html_content).to_text.gsub(/\n{3,}/, "\n\n").strip
    end

    private

    def sanitize(content)
      ActionController::Base.helpers.sanitize(content, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
    end
  end
end
