# Records which API token, if any, a parking notice's history entry came in through.
class AddApiTokenToParkingNoticeEvents < ActiveRecord::Migration[8.1]
  def change
    add_reference :parking_notice_events, :api_token, foreign_key: { on_delete: :nullify }
  end
end
