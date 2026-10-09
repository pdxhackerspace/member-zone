require 'test_helper'

class WebhookDeviceTest < ActiveSupport::TestCase
  test 'creating a device issues a token and stores only its digest' do
    device = WebhookDevice.create!(name: 'Front door kiosk')

    assert device.token.present?
    assert_equal WebhookDevice.digest(device.token), device.token_digest
    assert_equal device.token.last(4), device.token_hint
    assert_nil WebhookDevice.find(device.id).token, 'the plaintext token must not be recoverable'
  end

  test 'authenticate finds an enabled device by token' do
    device = WebhookDevice.create!(name: 'Front door kiosk')

    assert_equal device, WebhookDevice.authenticate(device.token)
    assert_nil WebhookDevice.authenticate('not-the-token')
    assert_nil WebhookDevice.authenticate('')
  end

  test 'a disabled device does not authenticate' do
    device = WebhookDevice.create!(name: 'Front door kiosk', enabled: false)

    assert_nil WebhookDevice.authenticate(device.token)
  end

  test 'regenerating the token retires the old one' do
    device = WebhookDevice.create!(name: 'Front door kiosk')
    old_token = device.token

    new_token = device.regenerate_token!

    assert_not_equal old_token, new_token
    assert_nil WebhookDevice.authenticate(old_token)
    assert_equal device, WebhookDevice.authenticate(new_token)
  end
end
