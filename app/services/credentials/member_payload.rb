module Credentials
  # The member details a program is given on stdin: enough to name the credential at the
  # provider, and nothing sensitive beyond the email address the provider will usually need.
  module MemberPayload
    module_function

    def call(user)
      { uid: user.authentik_id.presence || user.id.to_s, username: user.username.to_s,
        name: user.display_name.to_s, email: user.email.to_s }
    end

    # The JSON on stdin for revoke, pause and resume.
    def for_credential(credential, reason)
      JSON.generate(request_id: credential.request_id, external_id: credential.external_id,
                    reason: reason.to_s, member: call(credential.user))
    end
  end
end
