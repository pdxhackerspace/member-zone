#!/bin/sh
# Describes itself properly, then answers issue with something that is not JSON.
. "$(dirname "$0")/_common.sh"

case "$action" in
  describe) describe_oauth ;;
  health) printf '{"ok":true}\n' ;;
  issue) printf 'not json {"client_secret":"abcd-secret-value-wxyz"\n' ;;
  revoke) exit 0 ;;
esac
