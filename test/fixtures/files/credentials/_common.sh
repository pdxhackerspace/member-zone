# Shared by the fixture programs. Not executable, so it never appears in the script picker.
#
# Environment switches (set through the provider's environment variables):
#   STATE_DIR       directory to record every call in: calls.log, and <action>.stdin
#   SECRET          the secret issued as client_secret (default abcd-secret-value-wxyz)
#   EXPIRES_AT      an expires_at to report from issue
#   NO_PAUSE        leave pause and resume out of describe
#   UNHEALTHY       health reports ok:false
#   HEALTH_ECHOES_KEY  health reports ok:true with $API_KEY in its message
#   NOT_CONFIGURED  exit 2 for every action but describe
#   FAIL_ISSUE / FAIL_REVOKE / FAIL_PAUSE / FAIL_RESUME   exit 1 for that action

action="$1"
input="$(cat)"

if [ -n "$STATE_DIR" ]; then
  printf '%s\n' "$*" >> "$STATE_DIR/calls.log"
  printf '%s' "$input" > "$STATE_DIR/$action.stdin"
fi

request_id="$(printf '%s' "$input" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')"
short_id="$(printf '%s' "$request_id" | cut -c1-8)"

describe_oauth() {
  actions='"issue","revoke","health","pause","resume"'
  [ -n "$NO_PAUSE" ] && actions='"issue","revoke","health"'
  printf '{"protocol":1,"name":"Fixture OAuth client","description":"A client id and secret.",'
  printf '"fields":[{"key":"client_id","label":"Client ID","secret":false},'
  printf '{"key":"client_secret","label":"Client secret","secret":true}],"actions":[%s]}\n' "$actions"
}

issue_oauth() {
  secret="${SECRET:-abcd-secret-value-wxyz}"
  expiry=''
  [ -n "$EXPIRES_AT" ] && expiry=",\"expires_at\":\"$EXPIRES_AT\""
  printf '{"external_id":"ext-%s","fields":{"client_id":"client-%s","client_secret":"%s"}%s}\n' \
    "$request_id" "$short_id" "$secret" "$expiry"
}

fail_if() {
  if [ -n "$1" ]; then
    echo "simulated failure" >&2
    exit 1
  fi
}

not_configured_check() {
  if [ -n "$NOT_CONFIGURED" ]; then
    echo "not configured" >&2
    exit 2
  fi
}
