class EmailTemplate
  # Sample values for the device-issued parking permit templates; see PreviewVariables for why
  # every variable needs one.
  module ParkingPermitDevicePreviewVariables
    module_function

    def all
      {
        permit_form_url: "#{ENV.fetch('APP_BASE_URL', 'http://localhost:3000')}/parking_permit/sample-token",
        permit_form_expires_at: 'March 15, 2026 at 9:30 PM',
        permit_expires_at: 'March 29, 2026',
        device_name: 'Front door kiosk'
      }
    end
  end
end
