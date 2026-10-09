# The Reminders page's view of the blank parking permit reminder, kept out of
# ReminderSettingsController so the controller stays inside its size limit.
module ParkingPermitDetailsReminderData
  extend ActiveSupport::Concern

  private

  def parking_permit_details_counts
    { due: Reminders::ParkingPermitDetailsEligibility.count_due,
      context: "#{Reminders::ParkingPermitDetailsEligibility.total_awaiting} blank permits awaiting details",
      note: 'Sent directly rather than through the mail queue: each reminder carries a link that expires in ' \
            '12 hours, which review could outlast.' }
  end

  def load_parking_permit_details_show_data
    @pagy, @due_notices = pagy(Reminders::ParkingPermitDetailsEligibility.due, limit: self.class::PER_PAGE)
    @parking_permit_details_due_count = @pagy.count
    @parking_permit_details_awaiting_count = Reminders::ParkingPermitDetailsEligibility.total_awaiting
    load_delivery_index(@due_notices)
  end
end
