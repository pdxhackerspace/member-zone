# The Reminders page's view of the arrival reminder, kept out of ReminderSettingsController
# so the controller stays inside its size limit.
module ParkingArrivalReminderData
  extend ActiveSupport::Concern

  private

  def parking_arrival_counts
    { due: Reminders::ParkingArrivalEligibility.count_with_open_notices,
      due_label: 'members with open notices',
      context: "#{Reminders::ParkingArrivalEligibility.reminded_today_count} reminded today",
      note: 'Sent when the member arrives, not on the daily run. A notice issued inside the repeat ' \
            'window is left out, because the issued email has only just gone out.' }
  end

  def load_parking_arrival_show_data
    members = Reminders::ParkingArrivalEligibility.members_with_open_notices
    @pagy, @parking_arrival_members = pagy(members, limit: self.class::PER_PAGE)
    @parking_arrival_member_count = @pagy.count
    @parking_arrival_reminded_today = Reminders::ParkingArrivalEligibility.reminded_today_count
    @open_notice_counts = Reminders::ParkingArrivalEligibility.open_notice_counts(@parking_arrival_members.map(&:id))
    load_delivery_index(@parking_arrival_members)
  end
end
