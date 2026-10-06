#!/bin/sh
# Returns a field describe never declared.
. "$(dirname "$0")/_common.sh"

case "$action" in
  describe) describe_oauth ;;
  health) printf '{"ok":true}\n' ;;
  issue)
    printf '{"external_id":"ext-%s","fields":{"client_id":"client-%s","client_secret":"abcd-secret-value-wxyz","surprise":"x"}}\n' \
      "$request_id" "$short_id"
    ;;
  revoke) fail_if "$FAIL_REVOKE" ;;
esac
