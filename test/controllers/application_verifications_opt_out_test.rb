require 'test_helper'

class ApplicationVerificationsOptOutTest < ActionDispatch::IntegrationTest
  setup do
    MembershipSetting.instance.update!(use_builtin_membership_application: true)
    ReminderSetting.seed_defaults!
    TextFragment.ensure_exists!(
      key: 'application_email_opted_out',
      title: 'Application email opted out',
      content: '<p>Please email info@pdxhackerspace.org to opt back in.</p>'
    )
  end

  test 'send_verification blocks opted-out email' do
    EmailNotificationOptOut.opt_out!('opted-out-gate@example.com', category: 'application_link')

    assert_no_difference 'ApplicationVerification.count' do
      post apply_new_path, params: gate_params(email: 'opted-out-gate@example.com')
    end
    assert_response :unprocessable_content
    assert_match 'info@pdxhackerspace.org', response.body
  end

  test 'send_verification allows subscribed email' do
    assert_difference 'ApplicationVerification.count', 1 do
      post apply_new_path, params: gate_params(email: 'fresh-applicant@example.com')
    end
    assert_redirected_to apply_check_email_path
  end

  private

  def gate_params(email:)
    {
      confirmed_open_house: '1',
      confirmed_code_of_conduct: '1',
      email: email
    }
  end
end
