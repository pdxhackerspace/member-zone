#!/bin/sh
# Exit 2 for everything except describe: the provider has no credentials of its own yet.
. "$(dirname "$0")/_common.sh"

if [ "$action" = "describe" ]; then describe_oauth; exit 0; fi
echo "API_TOKEN is not set" >&2
exit 2
