class CreateParkingNoticeMembers < ActiveRecord::Migration[8.1]
  def up
    create_table :parking_notice_members do |t|
      t.references :parking_notice, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end

    add_index :parking_notice_members, %i[parking_notice_id user_id], unique: true

    execute <<~SQL.squish
      INSERT INTO parking_notice_members (parking_notice_id, user_id, created_at, updated_at)
      SELECT id, user_id, created_at, updated_at
      FROM parking_notices
      WHERE user_id IS NOT NULL
    SQL

    remove_reference :parking_notices, :user, foreign_key: true
  end

  def down
    add_reference :parking_notices, :user, null: true, foreign_key: true

    execute <<~SQL.squish
      UPDATE parking_notices pn
      SET user_id = (
        SELECT pnm.user_id
        FROM parking_notice_members pnm
        WHERE pnm.parking_notice_id = pn.id
        ORDER BY pnm.created_at ASC, pnm.id ASC
        LIMIT 1
      )
    SQL

    drop_table :parking_notice_members
  end
end
