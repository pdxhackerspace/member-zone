#!/bin/sh
# Describes quickly, then hangs, leaving a child behind. $STATE_DIR/pid holds the pid of
# that child so a test can prove the whole process group was killed.
. "$(dirname "$0")/_common.sh"

if [ "$action" = "describe" ]; then describe_oauth; exit 0; fi
sleep 60 &
[ -n "$STATE_DIR" ] && echo $! > "$STATE_DIR/pid"
sleep 60
