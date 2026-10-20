#!/bin/sh
# Issues a secret too short to hint safely.
. "$(dirname "$0")/_common.sh"

case "$action" in
  describe) describe_oauth ;;
  health) printf '{"ok":true}\n' ;;
  issue) SECRET=short1 issue_oauth ;;
  revoke) exit 0 ;;
esac
