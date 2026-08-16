module Api
  class UsersController < AuthenticatedController
    # The member picker behind every "link this to a member" control. It answers with names
    # and email addresses, so it needs a grant of its own rather than riding on whichever
    # page happens to embed it.
    before_action -> { require_privilege!(:'api.users.search') }

    def search
      q = params[:q].to_s.strip

      if q.blank?
        render json: []
        return
      end

      pattern = "%#{q.downcase}%"

      # Email is encrypted, so it cannot be matched by substring like the other fields.
      # A whole address still resolves through the lookup digest.
      #
      # The answer carries email addresses, so a holder who cannot read a profile is not
      # given one here either — see MemberVisibility.
      users = members_visible_to_viewer(
        User.where(
          "LOWER(COALESCE(full_name, '')) LIKE :p " \
          "OR LOWER(COALESCE(username, '')) LIKE :p " \
          'OR EXISTS (SELECT 1 FROM unnest(aliases) AS a WHERE LOWER(a) LIKE :p)',
          p: pattern
        ).or(User.by_any_email(q))
      ).ordered_by_display_name.limit(20)

      render json: users.map { |u| { id: u.id, name: u.display_name, email: u.email } }
    end
  end
end
