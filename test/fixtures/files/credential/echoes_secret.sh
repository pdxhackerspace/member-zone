#!/bin/sh
# A careless program: issues fine, but logs the secret it just issued to stderr.
. "$(dirname "$0")/_common.sh"

case "$action" in
  describe) describe_oauth ;;
  health) printf '{"ok":true}\n' ;;
  issue)
    issue_oauth
    echo "debug: issued secret abcd-secret-value-wxyz for client-$short_id" >&2
    ;;
  revoke) exit 0 ;;
esac
