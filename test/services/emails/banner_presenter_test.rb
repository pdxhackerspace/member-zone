require 'test_helper'

module Emails
  class BannerPresenterTest < ActiveSupport::TestCase
    test 'for_email returns nil when fragment is blank' do
      TextFragment.ensure_exists!(key: 'outgoing_email_banner', title: 'Outgoing email banner', content: '')
      TextFragment.find_by!(key: 'outgoing_email_banner').update!(content: '')

      assert_nil BannerPresenter.for_email
    end

    test 'for_email returns presenter with sanitized html and plain text' do
      TextFragment.ensure_exists!(
        key: 'outgoing_email_banner',
        title: 'Outgoing email banner',
        content: '<p>Office closed <strong>Monday</strong>.</p>'
      )

      banner = BannerPresenter.for_email

      assert_predicate banner, :present?
      assert_includes banner.html, 'Office closed'
      assert_includes banner.html, '<strong>Monday</strong>'
      assert_not_includes banner.html, '<script'
      assert_includes banner.text, 'Office closed'
      assert_includes banner.text, 'Monday'
    end
  end
end
