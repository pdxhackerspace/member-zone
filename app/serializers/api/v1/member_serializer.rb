module Api
  module V1
    # A member as the API shows them: enough to pick and identify someone, no more.
    module MemberSerializer
      module_function

      def call(user)
        {
          id: user.id,
          name: user.display_name,
          username: user.username,
          email: user.email,
          active: user.active?
        }
      end
    end
  end
end
