class DescribeLapsedAccessVisitsInEmail < ActiveRecord::Migration[8.1]
  OLD_PHRASE = 'facilities yesterday'.freeze
  NEW_PHRASE = 'facilities {{access_summary}}'.freeze
  OLD_DESCRIPTION = 'Sent when an inactive member badged in yesterday'.freeze
  NEW_DESCRIPTION = 'Sent when an inactive member badged in within the reminder lookback window'.freeze

  def up
    swap_phrase(OLD_PHRASE, NEW_PHRASE)
    swap_description(OLD_DESCRIPTION, NEW_DESCRIPTION)
  end

  def down
    swap_phrase(NEW_PHRASE, OLD_PHRASE)
    swap_description(NEW_DESCRIPTION, OLD_DESCRIPTION)
  end

  private

  # A targeted REPLACE rather than a rewrite of the whole body: an admin who reworded the rest of
  # the email keeps their copy, and only the claim that has stopped being true changes.
  def swap_phrase(from, to)
    execute(<<~SQL.squish)
      UPDATE email_templates
      SET body_html = REPLACE(body_html, #{connection.quote(from)}, #{connection.quote(to)}),
          body_text = REPLACE(body_text, #{connection.quote(from)}, #{connection.quote(to)}),
          updated_at = NOW()
      WHERE key = 'lapsed_access_reminder'
    SQL
  end

  def swap_description(from, to)
    execute(<<~SQL.squish)
      UPDATE email_templates
      SET description = #{connection.quote(to)}, updated_at = NOW()
      WHERE key = 'lapsed_access_reminder'
        AND description = #{connection.quote(from)}
    SQL
  end
end
