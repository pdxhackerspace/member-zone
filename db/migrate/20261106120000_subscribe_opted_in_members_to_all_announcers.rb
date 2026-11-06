# Members who switched announcements on but ticked no announcer were never announced anywhere.
# Saving the Visibility step now treats that as every announcer; this gives members already in
# that state the same, by subscribing them to every enabled announcer. Anyone with at least one
# enabled announcer ticked is left as they are.
class SubscribeOptedInMembersToAllAnnouncers < ActiveRecord::Migration[8.1]
  def change
    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          INSERT INTO announcer_subscriptions (user_id, announcer_id, created_at, updated_at)
          SELECT users.id, announcers.id, NOW(), NOW()
          FROM users CROSS JOIN announcers
          WHERE users.announce_arrivals AND announcers.enabled
            AND NOT EXISTS (
              SELECT 1 FROM announcer_subscriptions existing
              JOIN announcers chosen ON chosen.id = existing.announcer_id
              WHERE existing.user_id = users.id AND chosen.enabled
            )
          ON CONFLICT (user_id, announcer_id) DO NOTHING
        SQL
      end
    end
  end
end
