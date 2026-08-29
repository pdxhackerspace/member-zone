require 'test_helper'

module Emails
  class BodyComposerTest < ActiveSupport::TestCase
    setup do
      ReminderSetting.seed_defaults!
      ReminderSetting.find_by!(key: 'payment_overdue').update!(allow_opt_out: true)
      write_banner('<p>Office closed <strong>Monday</strong>.</p>')
      @user = users(:member_with_local_account)
    end

    test 'for_preview wraps body in the mailer layout with banner and opt-out footer' do
      preview = BodyComposer.for_preview(
        body_html: '<p>Your dues are past due.</p>',
        body_text: 'Your dues are past due.',
        mailer_action: 'payment_past_due',
        user: @user,
        email: @user.email
      )

      assert_includes preview.html, 'email-wrapper'
      assert_includes preview.html, 'email-banner'
      assert_includes preview.html, 'Office closed'
      assert_includes preview.html, 'Your dues are past due.'
      assert_includes preview.html, 'notification-footer'
      assert_includes preview.html, 'Manage overdue payment reminders'

      assert_operator preview.html.index('Office closed'), :<, preview.html.index('Your dues are past due.')
      assert_operator preview.html.index('Your dues are past due.'), :<, preview.html.index('notification-footer')
    end

    test 'for_preview orders banner, body, and footer in the plain text version' do
      preview = BodyComposer.for_preview(
        body_html: '<p>Your dues are past due.</p>',
        body_text: 'Your dues are past due.',
        mailer_action: 'payment_past_due',
        user: @user,
        email: @user.email
      )

      assert_operator preview.text.index('Office closed'), :<, preview.text.index('Your dues are past due.')
      assert_operator preview.text.index('Your dues are past due.'), :<,
                      preview.text.index('Manage overdue payment reminders')
    end

    test 'for_preview omits the banner when the fragment is blank' do
      write_banner('')

      preview = BodyComposer.for_preview(body_html: '<p>Body.</p>', body_text: 'Body.',
                                         mailer_action: 'payment_past_due', user: @user)

      assert_no_match(/<div class="email-banner">/, preview.html)
      assert_equal 'Body.', preview.text.lines.first.strip
    end

    test 'for_preview renders a mandatory notice for categories that cannot be turned off' do
      ReminderSetting.find_by!(key: 'parking_notices').update!(allow_opt_out: false)

      preview = BodyComposer.for_preview(
        body_html: '<p>Your permit expires soon.</p>',
        mailer_action: 'parking_permit_expiring_soon',
        user: @user,
        email: @user.email
      )

      assert_includes preview.html, 'This is a required notice and cannot be turned off.'
    end

    test 'for_preview has no footer for admin-only actions' do
      preview = BodyComposer.for_preview(
        body_html: '<p>New application.</p>',
        body_text: 'New application.',
        mailer_action: 'staff_application_reminder',
        user: @user,
        email: @user.email
      )

      assert_not_includes preview.html, 'notification-footer'
      assert_includes preview.html, 'Office closed'
    end

    # A SafeBuffer here would slip through ERB::Util.html_escape untouched and break out of the
    # iframe srcdoc attribute at the layout's first double quote.
    test 'html is escapable so it survives an iframe srcdoc attribute' do
      composed = BodyComposer.html(body_html: '<p>Body.</p>')

      assert_not composed.html_safe?
      assert_includes ERB::Util.html_escape(composed), '&lt;!DOCTYPE html&gt;'
    end

    test 'text returns nil when there is nothing to compose' do
      assert_nil BodyComposer.text
    end

    private

    def write_banner(content)
      TextFragment.ensure_exists!(key: 'outgoing_email_banner', title: 'Outgoing email banner', content: '')
      TextFragment.find_by!(key: 'outgoing_email_banner').update!(content: content)
    end
  end
end
