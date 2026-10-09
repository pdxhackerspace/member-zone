# Adds the device-issued parking permit email templates and the reminder that nudges members to
# fill in a blank permit to databases that already exist. Fresh databases get them from db:seed.
class SeedParkingPermitDeviceTemplates < ActiveRecord::Migration[8.1]
  TEMPLATE_KEYS = %w[parking_permit_form_link parking_permit_blank_issued parking_permit_details_reminder].freeze

  def up
    EmailTemplate.seed_defaults!
    ReminderSetting.seed_defaults!
  end

  def down
    EmailTemplate.where(key: TEMPLATE_KEYS).destroy_all
    ReminderSetting.where(key: 'parking_permit_details').destroy_all
  end
end
