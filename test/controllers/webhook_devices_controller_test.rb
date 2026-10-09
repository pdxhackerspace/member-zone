require 'test_helper'

class WebhookDevicesControllerTest < ActionDispatch::IntegrationTest
  test 'creating a device shows its token once' do
    with_local_auth do
      sign_in_as_admin

      assert_difference 'WebhookDevice.count', 1 do
        post webhook_devices_path, params: { webhook_device: { name: 'Front door kiosk', enabled: '1' } }
      end
      device = WebhookDevice.last
      follow_redirect!
      token = css_select('code.user-select-all').first&.text

      assert_equal device, WebhookDevice.authenticate(token)

      get webhook_device_path(device)
      assert_select 'code.user-select-all', count: 0
    end
  end

  test 'regenerating the token issues a new one' do
    device = WebhookDevice.create!(name: 'Front door kiosk')
    old_token = device.token

    with_local_auth do
      sign_in_as_admin
      post regenerate_token_webhook_device_path(device)
    end

    assert_nil WebhookDevice.authenticate(old_token)
  end

  test 'members without the privilege cannot manage devices' do
    with_local_auth do
      sign_in_as_plain_member

      get webhook_devices_path
      assert_response :redirect

      assert_no_difference 'WebhookDevice.count' do
        post webhook_devices_path, params: { webhook_device: { name: 'Sneaky' } }
      end
    end
  end
end
