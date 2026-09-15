class LinkParkingNoticeInParkingEmails < ActiveRecord::Migration[8.1]
  PERMIT_KEYS = %w[
    parking_permit_issued parking_permit_expired parking_permit_expiring_soon
    parking_permit_overdue_reminder parking_permit_final_reminder
  ].freeze

  TICKET_KEYS = %w[
    parking_ticket_issued parking_ticket_expired parking_ticket_expiring_soon
    parking_ticket_overdue_reminder parking_ticket_final_reminder
  ].freeze

  PERMIT_LABEL = 'View your parking permit'.freeze
  TICKET_LABEL = 'View this parking ticket'.freeze

  def up
    add_link(PERMIT_KEYS, PERMIT_LABEL)
    add_link(TICKET_KEYS, TICKET_LABEL)
  end

  def down
    remove_link(PERMIT_KEYS, PERMIT_LABEL)
    remove_link(TICKET_KEYS, TICKET_LABEL)
  end

  private

  # Appended rather than written into the body: an admin who reworded the email keeps their copy,
  # and the link lands where these templates already end, after the instruction to act.
  def add_link(keys, label)
    execute(<<~SQL)
      UPDATE email_templates
      SET body_html = body_html || #{connection.quote(html_link(label))},
          body_text = body_text || #{connection.quote(text_link(label))},
          updated_at = NOW()
      WHERE key IN (#{quoted_keys(keys)})
        AND body_html NOT LIKE #{connection.quote('%{{parking_notice_url}}%')}
    SQL
  end

  def remove_link(keys, label)
    execute(<<~SQL)
      UPDATE email_templates
      SET body_html = REPLACE(body_html, #{connection.quote(html_link(label))}, ''),
          body_text = REPLACE(body_text, #{connection.quote(text_link(label))}, ''),
          updated_at = NOW()
      WHERE key IN (#{quoted_keys(keys)})
    SQL
  end

  def html_link(label)
    %(<p><a href="{{parking_notice_url}}">#{label}</a></p>\n)
  end

  def text_link(label)
    "\n#{label}: {{parking_notice_url}}\n"
  end

  def quoted_keys(keys)
    keys.map { |key| connection.quote(key) }.join(', ')
  end
end
