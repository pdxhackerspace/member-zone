module AvatarHelper
  def avatar_image_tag(user, size:, src: nil, **)
    fallback = gravatar_url(user.email, size: size)
    image_tag(src || user.avatar.presence || fallback, **, data: {
                controller: 'avatar',
                action: 'error->avatar#fallback',
                avatar_fallback_url_value: fallback
              })
  end
end
