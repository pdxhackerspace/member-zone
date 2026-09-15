require 'test_helper'

class MailDeliveryReadinessTest < ActiveSupport::TestCase
  test 'non-SMTP delivery methods are always ready' do
    with_mailer_config(delivery_method: :test, smtp_settings: nil) do
      assert MailDeliveryReadiness.available?
      assert_nil MailDeliveryReadiness.unavailable_reason
    end
  end

  test 'letter_opener is ready even with no SMTP settings' do
    with_mailer_config(delivery_method: :letter_opener, smtp_settings: {}) do
      assert MailDeliveryReadiness.available?
    end
  end

  test 'configured SMTP is ready' do
    with_mailer_config(delivery_method: :smtp, smtp_settings: { address: 'smtp.example.org' }) do
      assert MailDeliveryReadiness.available?
    end
  end

  test 'SMTP without credentials is still worth attempting' do
    settings = { address: 'smtp.example.org', user_name: nil, password: nil }
    with_mailer_config(delivery_method: :smtp, smtp_settings: settings) do
      assert MailDeliveryReadiness.available?
    end
  end

  test 'SMTP left on the placeholder host is not ready' do
    with_mailer_config(delivery_method: :smtp, smtp_settings: { address: 'smtp.example.com' }) do
      assert_not MailDeliveryReadiness.available?
      assert_match(/placeholder host/, MailDeliveryReadiness.unavailable_reason)
    end
  end

  test 'SMTP with no address is not ready' do
    with_mailer_config(delivery_method: :smtp, smtp_settings: { address: '' }) do
      assert_not MailDeliveryReadiness.available?
      assert_match(/no SMTP server is configured/, MailDeliveryReadiness.unavailable_reason)
    end
  end

  private

  def with_mailer_config(delivery_method:, smtp_settings:)
    config = Rails.configuration.action_mailer
    original_method = config.delivery_method
    original_settings = config.smtp_settings
    config.delivery_method = delivery_method
    config.smtp_settings = smtp_settings
    yield
  ensure
    config.delivery_method = original_method
    config.smtp_settings = original_settings
  end
end
