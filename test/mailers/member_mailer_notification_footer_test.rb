require 'test_helper'

class MemberMailerNotificationFooterTest < ActionMailer::TestCase
  setup do
    @user = users(:member_with_local_account)
    ReminderSetting.seed_defaults!
  end

  test 'payment_past_due includes opt-out footer in html and text' do
    EmailTemplate.where(key: 'payment_past_due').delete_all
    mail = MemberMailer.payment_past_due(@user, days_overdue: 7)

    assert_includes mail.html_part.body.decoded, 'notification settings'
    assert_includes mail.text_part.body.decoded, 'Manage overdue payment reminders'
  end

  test 'parking_permit_issued includes mandatory footer' do
    EmailTemplate.where(key: 'parking_permit_issued').delete_all
    mail = MemberMailer.parking_permit_issued(
      @user,
      location: 'Lot A',
      location_detail: '',
      description: 'Test',
      expires_at: 1.week.from_now.to_fs(:long),
      notice_type: 'permit'
    )

    html = mail.html_part&.body&.decoded || mail.body.decoded
    assert_includes html, 'required notice'
    text = mail.text_part&.body&.decoded
    assert_includes text, 'required notice' if text.present?
  end
end
