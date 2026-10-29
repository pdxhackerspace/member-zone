#!/bin/sh
# Prints the provider's API key to stderr and fails, as a careless program might.
. "$(dirname "$0")/_common.sh"

case "$action" in
  describe) describe_oauth ;;
  *) echo "request failed using key $API_KEY" >&2; exit 1 ;;
esac
