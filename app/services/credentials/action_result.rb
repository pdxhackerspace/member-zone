module Credentials
  # What a lifecycle service (revoke, pause, resume) reports back. The error is safe to show:
  # it comes from Invocation, which never lets a secret into a message.
  ActionResult = Struct.new(:ok, :error, :credential, keyword_init: true) do
    alias_method :ok?, :ok
  end
end
