#!/bin/sh
# Prints a secret and a handle, then exits 3: whatever it printed is not to be trusted, but
# the handle is worth a revoke.
. "$(dirname "$0")/_common.sh"

case "$action" in
  describe) describe_oauth ;;
  health) echo "boom" >&2; exit 3 ;;
  issue)
    printf '{"external_id":"ext-partial","fields":{"client_id":"c","client_secret":"abcd-secret-value-wxyz"}}\n'
    echo "something went wrong" >&2
    exit 3
    ;;
  revoke) fail_if "$FAIL_REVOKE" ;;
esac
