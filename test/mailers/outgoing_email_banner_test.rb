require 'test_helper'

class OutgoingEmailBannerTest < ActionMailer::TestCase
  setup do
    @user = users(:member_with_local_account)
    ReminderSetting.seed_defaults!
    EmailTemplate.where(key: 'payment_past_due').delete_all
  end

  test 'member mail includes banner at top when fragment is set' do
    TextFragment.ensure_exists!(
      key: 'outgoing_email_banner',
      title: 'Outgoing email banner',
      content: '<p>Holiday hours: closed December 25.</p>'
    )

    mail = MemberMailer.payment_past_due(@user, days_overdue: 7)
    html = mail.html_part.body.decoded
    text = mail.text_part.body.decoded

    banner_index = html.index('Holiday hours: closed December 25.')
    body_index = html.index('Payment Reminder') || html.index('past due') || html.index(@user.display_name)
    assert banner_index, 'expected banner in html'
    assert body_index, 'expected message body in html'
    assert_operator banner_index, :<, body_index
    assert_includes text, 'Holiday hours: closed December 25.'
  end

  test 'member mail omits banner when fragment is empty' do
    TextFragment.ensure_exists!(key: 'outgoing_email_banner', title: 'Outgoing email banner', content: '')
    TextFragment.find_by!(key: 'outgoing_email_banner').update!(content: '')

    mail = MemberMailer.payment_past_due(@user, days_overdue: 7)
    html = mail.html_part.body.decoded

    assert_no_match(/<div class="email-banner">/, html)
  end

  test 'queued mail includes banner when fragment is set' do
    TextFragment.ensure_exists!(
      key: 'outgoing_email_banner',
      title: 'Outgoing email banner',
      content: '<p>Queued mail banner notice.</p>'
    )
    qm = queued_mails(:pending_mail)

    mail = QueuedMailMailer.deliver_queued(qm)
    html = mail.html_part.body.decoded
    text = mail.text_part.body.decoded

    assert_includes html, 'Queued mail banner notice.'
    assert_includes html, 'email-banner'
    assert_includes text, 'Queued mail banner notice.'
    assert_operator text.index('Queued mail banner notice.'), :<, text.index(qm.body_text.strip.lines.first.strip)
  end

  test 'templated member mail puts banner before body in text part' do
    TextFragment.ensure_exists!(
      key: 'outgoing_email_banner',
      title: 'Outgoing email banner',
      content: '<p>Top announcement.</p>'
    )
    EmailTemplate.create!(
      key: 'payment_past_due',
      name: 'Payment past due',
      enabled: true,
      subject: 'Payment due',
      body_html: '<p>Template body for {{member_name}}.</p>',
      body_text: 'Template body for {{member_name}}.'
    )

    mail = MemberMailer.payment_past_due(@user, days_overdue: 7)
    text = mail.text_part.body.decoded

    assert_operator text.index('Top announcement.'), :<, text.index('Template body for Regular Member.')
  end
end
