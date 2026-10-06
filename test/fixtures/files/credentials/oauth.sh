#!/bin/sh
# The full protocol: two fields (one not secret), pause and resume, behaviour switched by
# environment variables. See _common.sh.
. "$(dirname "$0")/_common.sh"

case "$action" in
  describe) describe_oauth ;;
  health)
    not_configured_check
    if [ -n "$UNHEALTHY" ]; then printf '{"ok":false,"message":"upstream is down"}\n'
    elif [ -n "$HEALTH_ECHOES_KEY" ]; then printf '{"ok":true,"message":"checked with %s"}\n' "$API_KEY"
    else printf '{"ok":true,"message":"all good"}\n'; fi
    ;;
  issue) not_configured_check; fail_if "$FAIL_ISSUE"; issue_oauth ;;
  revoke) not_configured_check; fail_if "$FAIL_REVOKE" ;;
  pause) not_configured_check; fail_if "$FAIL_PAUSE" ;;
  resume) not_configured_check; fail_if "$FAIL_RESUME" ;;
  *) echo "unknown action" >&2; exit 64 ;;
esac
