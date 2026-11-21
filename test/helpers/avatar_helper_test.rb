require 'test_helper'

class AvatarHelperTest < ActionView::TestCase
  include ApplicationHelper
  include AvatarHelper

  test 'avatar includes the saved URL and a Gravatar error fallback' do
    user = users(:two)
    user.avatar = 'https://avatars.slack-edge.com/photo.png'

    fragment = Nokogiri::HTML.fragment(avatar_image_tag(user, size: 44, alt: user.display_name))
    image = fragment.at_css('img')

    assert_equal user.avatar, image['src']
    assert_equal 'avatar', image['data-controller']
    assert_equal 'error->avatar#fallback', image['data-action']
    assert_equal gravatar_url(user.email, size: 44), image['data-avatar-fallback-url-value']
  end

  test 'avatar uses Gravatar when there is no saved URL' do
    user = users(:two)
    user.avatar = nil

    fragment = Nokogiri::HTML.fragment(avatar_image_tag(user, size: 32))

    assert_equal gravatar_url(user.email, size: 32), fragment.at_css('img')['src']
  end
end
