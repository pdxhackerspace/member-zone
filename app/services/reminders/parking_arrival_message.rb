module Reminders
  # The open-notice list an arrival reminder inserts into its template. Templates cannot
  # loop, so the mailer hands them a finished fragment rather than one notice's fields.
  class ParkingArrivalMessage
    def self.call(user, notices)
      new(user, notices).to_h
    end

    def initialize(user, notices)
      @user = user
      @notices = notices
    end

    def to_h
      { notices_html: html, notices_text: text, notice_count: @notices.size.to_s }
    end

    private

    def html
      @notices.map { |notice| html_notice(notice) }.join("\n")
    end

    def text
      @notices.map { |notice| text_notice(notice) }.join("\n\n")
    end

    def html_notice(notice)
      lines = [heading(notice), escaped(notice.description), "Expires #{escaped(expires(notice))}", button(notice)]
      "<p>#{lines.compact_blank.join('<br>')}</p>"
    end

    def text_notice(notice)
      [heading_text(notice), plain(notice.description), "Expires #{plain(expires(notice))}",
       "#{action_label(notice)}: #{clearance_url(notice)}"].compact_blank.join("\n")
    end

    def heading(notice)
      "<strong>#{escaped(notice.notice_type_display)}</strong> — #{escaped(place(notice))}"
    end

    def heading_text(notice)
      "#{plain(notice.notice_type_display)} — #{plain(place(notice))}"
    end

    def button(notice)
      %(<a href="#{escape(clearance_url(notice))}" ) \
        'style="display:inline-block;padding:8px 14px;background:#0d6efd;color:#ffffff;' \
        'text-decoration:none;border-radius:4px;">' \
        "#{escape(action_label(notice))}</a>"
    end

    def action_label(notice)
      notice.clearable_by?(@user) ? "Clear this #{notice.notice_type}" : 'Request clearance'
    end

    def place(notice)
      notice.location_display.presence || 'the space'
    end

    def expires(notice)
      notice.expires_at.strftime('%B %d, %Y')
    end

    def clearance_url(notice)
      token = membership_for(notice).generate_token_for(:arrival_clearance)
      options = Rails.application.config.action_mailer.default_url_options || {}
      Rails.application.routes.url_helpers.parking_clearance_url(token, **options)
    end

    def membership_for(notice)
      memberships.fetch(notice.id)
    end

    def memberships
      @memberships ||= ParkingNoticeMember.where(user: @user, parking_notice: @notices).index_by(&:parking_notice_id)
    end

    # Template rendering strips any leftover {{token}}. A description that itself contains
    # one would be eaten out of the surrounding sentence, so braces never reach the template.
    def plain(value)
      value.to_s.gsub(/[{}]/, '').squish
    end

    def escaped(value)
      escape(plain(value))
    end

    def escape(value)
      ERB::Util.html_escape(value.to_s)
    end
  end
end
