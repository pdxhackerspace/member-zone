# Which members a viewer may be shown in a list of members.
#
# A profile page already answers this, in UsersController#authorize_profile_view: an
# administrator or a holder of members.view_profile reads any profile, and everyone else
# reads only the ones whose owners opted into sharing. Listings have to answer it the same
# way. A search result that names someone whose own page would refuse the viewer hands over
# the fact of their membership regardless of what the link leads to, and the picker API
# hands over their email address with it.
module MemberVisibility
  extend ActiveSupport::Concern

  private

  # Holders of members.view_profile are included deliberately: the privilege is what the
  # front desk is given to identify whoever walks in, and withholding half the roster from a
  # search while the profiles themselves stay open would only send them to a different page.
  def can_view_hidden_profiles?
    current_user_admin? || can?(:'members.view_profile')
  end

  def members_visible_to_viewer(scope)
    return scope if can_view_hidden_profiles?

    scope.profile_visible_to(current_user)
  end
end
