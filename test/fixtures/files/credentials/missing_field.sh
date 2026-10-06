#!/bin/sh
# Issues a credential but leaves out client_secret, which describe declared. The credential
# exists at the provider, so MemberZone has to revoke it.
. "$(dirname "$0")/_common.sh"

case "$action" in
  describe) describe_oauth ;;
  health) printf '{"ok":true}\n' ;;
  issue) printf '{"external_id":"ext-%s","fields":{"client_id":"client-%s"}}\n' "$request_id" "$short_id" ;;
  revoke) fail_if "$FAIL_REVOKE" ;;
esac
