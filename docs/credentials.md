# Credentials manager

Members, and administrators on a member's behalf, can request a credential from an external
system: an API key, an app password, an OAuth client id and secret. A small program talks to
each system. MemberZone runs that program, shows the secret **once**, keeps only enough of it
to tell credentials apart, and keeps credentials in step with the member's standing.

## How it fits together

| Piece | Where |
| --- | --- |
| Provider: a program plus its encrypted environment | `CredentialProvider`, **Settings → Credential providers** |
| Credential: one issued credential belonging to a member | `Credential`, **Your credentials** (member) and **Admin → Credentials** |
| Run: a log of one program call | `CredentialRun`, on the provider's page |
| Programs | `scripts/credentials/` and `CREDENTIAL_SCRIPTS_DIR` |

Nothing ships in `scripts/credentials/`; every provider is specific to the system it talks to.
The program is **chosen from the executables found in the allowed directories**, never typed,
so editing a provider cannot be used to run an arbitrary binary.

### Where programs may live

A provider's program must resolve (after following symlinks) to an executable file inside one of:

- `scripts/credentials/` in the app (in the image, `/rails/scripts/credentials/`)
- the directory named by the `CREDENTIAL_SCRIPTS_DIR` environment variable, for programs an
  operator mounts in
- in tests only, `config.x.credential_script_directories` (`test/fixtures/files/credentials/`)

A file without an execute bit, a path that climbs out with `..`, and a symlink pointing outside
an allowed directory are all refused.

The check runs when a provider's program is chosen, and again before every run. A provider whose
program has since been removed, lost its execute bit, or left the allowed directories can still be
disabled or edited, but its program is not run: each action fails with "Program is no longer an
executable in a credential script directory" until it is pointed at one that is.

## The protocol

A program is run as `PROGRAM ACTION [arguments...]`. The arguments are the provider's
`script_arguments`, split on whitespace. There is no shell: the program is executed directly, so
spaces and metacharacters in a path or argument are just characters.

| Action | stdin | stdout | Required |
| --- | --- | --- | --- |
| `describe` | none | the schema | yes |
| `health` | none | `{"ok": true, "message": "..."}` | yes |
| `issue` | JSON | the credential | yes |
| `revoke` | JSON | ignored | yes |
| `pause` | JSON | ignored | with `resume` |
| `resume` | JSON | ignored | with `pause` |

Exit codes: `0` success, `2` not configured (the provider has no credentials of its own yet),
anything else failure. stderr is diagnostics: it is kept on the run, with secrets blanked out.

Timeouts: `describe` and `health` 15 seconds; `issue`, `revoke`, `pause` and `resume` 30 seconds.
On a timeout the program's whole process group is killed, so children do not linger.

### Environment

The program starts from an **empty** environment and receives only:

- the provider's environment variables (one `KEY=value` per line, stored encrypted)
- `CREDENTIAL_PROVIDER` (the provider's name) and `CREDENTIAL_ACTION`
- `PATH HOME LANG LC_ALL TZ TMPDIR SSL_CERT_FILE SSL_CERT_DIR HTTP_PROXY HTTPS_PROXY NO_PROXY`
  (and lower-case variants) and `SYSLOG_SERVER` / `SYSLOG_PORT`, if set

Nothing else from MemberZone's own process (`DATABASE_URL`, Rails secrets, Bundler settings)
reaches the program.

### `describe`

```json
{
  "protocol": 1,
  "name": "Authentik app password",
  "description": "A personal app password for API access.",
  "fields": [
    { "key": "client_id",     "label": "Client ID",     "secret": false },
    { "key": "client_secret", "label": "Client secret", "secret": true }
  ],
  "actions": ["issue", "revoke", "health", "pause", "resume"]
}
```

- `protocol` must be `1`. `name` and `description` are optional.
- `fields` lists what a credential consists of. Keys are lowercase letters, digits and
  underscores. `secret` defaults to `true`.
- `actions` must include `issue`, `revoke` and `health`. `pause` and `resume` are optional and
  must come together.

The answer is cached on the provider, refreshed by **Refresh schema** and whenever the program,
its arguments or its environment are changed. A failed refresh keeps the previous schema and
shows the error.

### `health`

`{"ok": true, "message": "..."}`. Healthy means exit 0 with `ok: true`. `ok: false`, a failure
exit, a timeout, or malformed output is unhealthy; exit 2 is "not configured". Health is checked
every ten minutes for every enabled provider and when a provider is saved. An unhealthy or
unconfigured provider is shown as needing attention and issues nothing until it recovers.

### `issue`

stdin:

```json
{
  "request_id": "b6f3c3a0-5a77-4c20-9c7a-0d4a1d3f9a11",
  "label": "laptop CLI",
  "member": { "uid": "<authentik id or user id>", "username": "...", "name": "...", "email": "..." }
}
```

stdout:

```json
{
  "external_id": "token-8812",
  "fields": { "client_id": "abc...", "client_secret": "s3cr..." },
  "expires_at": "2027-01-04T00:00:00Z"
}
```

- `external_id` is required: the handle MemberZone passes back to `revoke`, `pause` and `resume`.
- `fields` must have exactly the keys `describe` declared, each a non-empty string. Missing and
  extra fields are errors.
- `expires_at` is optional (ISO 8601). If the credential has an expiry, report it. Members do not
  choose one. A date in the past is an error.
- `request_id` is a UUID that is the same on a retry, so a program may make issuing idempotent.

If the output is malformed but still contains a usable `external_id`, MemberZone tries to
`revoke` it immediately rather than leave an untracked credential at the provider.

### `revoke`, `pause`, `resume`

stdin: `{"request_id", "external_id", "reason", "member": {...}}`. Only the exit code matters.
Revoking something that is already gone should exit 0. `reason` is a short word such as
`member_inactive`, `key_access_paused`, `key_access_resumed`, `rotated`, `revoked_by_member`,
`revoked_by_admin` or `issue_incomplete`.

## What is stored

| Stored | Not stored |
| --- | --- |
| For a **non-secret** field: the whole value | The secret itself, anywhere |
| For a **secret** field of 12 or more characters: its first 4 and last 4 characters | Any hint of a secret shorter than 12 characters |
| The program's `external_id`, expiry, status and timestamps | stdout of any `issue` call |
| stderr of each run, and the provider's health message, with environment values and issued strings blanked out (values under 5 characters, like `true`, are left alone) | Provider environment values in logs, journals or the UI |

The provider's environment variables are encrypted at rest (see
[docs/encrypted-fields.md](encrypted-fields.md)) and are never shown again after saving: the edit
form leaves them blank, a blank submission keeps the stored value, and a checkbox clears them.
`environment_variables` is also a filtered request parameter.

## Showing a secret once

Issuing is **synchronous** in the request, within the 30 second limit. The secret goes from the
program's stdout into memory and then into one HTTP response. It never touches Postgres, Redis,
Sidekiq, a job argument, an email or the log.

- The request form is a full-page post (`data-turbo="false"`) carrying a hidden `request_id` UUID.
- The response renders each field once with a Copy button and an "I've saved this" link, with
  `Cache-Control: no-store` and `Pragma: no-cache`.
- Repeating the post (refresh, double click, replay) is refused: a request id issues once. The
  member is told secrets are shown only once and to revoke and re-request if they did not save it.
- Going back in the browser shows nothing.
- Issuing and rotating are **refused while impersonating** a member, so an administrator never
  ends up holding a member's secret by accident. Administrators with
  *Issue and rotate credentials for members* use the explicit flow (**Admin → Credentials →
  Issue for member**, by the member's full email address), which records who issued it. Revoking
  while impersonating is allowed and is recorded against the real administrator.

## Who can be issued a credential

All of these must hold, and each failure is shown to the member with its reason:

- the provider is enabled, has described itself, and is not unhealthy or unconfigured
- the member is an active member and key access is not paused
- the member holds **every** training topic the provider requires
- the member is under the provider's *most per member* limit (pending, active and paused count)
- for a member asking for themselves: the provider allows self-service. Someone who holds
  *Issue and rotate credentials for members* (or an administrator) is not bound by this, including
  for their own credentials, so administrator-only providers are usable by the people who run them.

Standing is checked twice: before the program runs, and again once it returns. A member banned,
lapsed or paused while their credential was being issued is not shown it; it is revoked at once.

## Standing, pause, inactivity, expiry, rotation

- **Member stops being active** (lapse, cancellation to expiry, ban, death): every live
  credential is revoked (reason `member_inactive`) and the member is emailed a list. Reactivating
  restores nothing; they request new ones.
- **Key access paused**: a provider that lists `pause` and `resume` gets those calls and the
  credential becomes `paused`; resuming key access resumes it. A provider that does not list them
  has the credentials **revoked** (reason `key_access_paused`).
- **Expiry**: a week before an expiry the member gets one warning email; when the date passes the
  credential is marked `expired` and the member is told. `revoke` is **not** called; the provider's
  own program is what enforces its dates. An expired credential can still be revoked by hand.
- **Rotation** (**Replace** on a credential): issues a new credential with the same label, then
  revokes the old one with reason `rotated`, so there is never a gap. The two are linked. It works
  at the per-member limit. If the old one cannot be revoked yet, the new one is still shown, with a
  warning, and the revoke is retried. A credential with a replacement already on the way cannot be
  rotated again, so two Replace clicks at once leave one new credential, not two.
- A change of standing is acted on within moments by `Credentials::MemberSyncJob` (enqueued when
  `active` or `key_access_paused` changes). `Credentials::ReconcileJob` catches anything it misses.

### Credential states

```
pending --issue ok--> active <--> paused
   |                    |  \
   |                    |   --> expired
   \--issue failed--> failed
active/paused/expired --revoke ok--> revoked
                      --revoke failed--> revoke_failed (retried, flagged)
```

A `pending` row is written before the program runs, so a crash mid-issue leaves a record with the
request id. A pending row older than ten minutes is marked failed by the reconciler.

## Background jobs

| Job | Schedule | Purpose |
| --- | --- | --- |
| `Credentials::HealthCheckJob` | every 10 minutes | `health` for each enabled provider |
| `Credentials::ExpireJob` | 4:20 AM, after `Membership::TickJob` | expiry warnings and marking expired |
| `Credentials::ReconcileJob` | 4:30 AM | re-sync mismatched members; retry `revoke_failed` with exponential backoff (1h doubling, capped at 24h); fail stale `pending` |
| `Credentials::MemberSyncJob` | on change of standing | revoke, pause or resume one member's credentials |

## Privileges

| Key | Allows |
| --- | --- |
| `credentials.manage_providers` | configure providers (**Settings → Credential providers**) |
| `credentials.view_all` | see every issued credential (**Admin → Credentials**) |
| `credentials.issue_for_members` | issue and rotate on a member's behalf |
| `credentials.revoke` | revoke any member's credential |

Requesting your own credential needs no privilege. The `Credentials administrator` role bundles
all four. As everywhere, privileges reach members only through roles on training topics.

## Rake tasks

Every task that changes data has a dry-run twin; run the preview first.

```bash
rails 'credentials:describe[Provider name or id]'   # refresh the cached schema
rails 'credentials:health[Provider name or id]'     # run a health check now
rails credentials:expire_preview                    # what the daily expiry pass would do
rails credentials:expire
rails credentials:reconcile_preview                 # what the daily reconcile would do
rails credentials:reconcile
rails 'credentials:revoke_member_preview[USER_ID]'  # what revoking one member would revoke
rails 'credentials:revoke_member[USER_ID]'
```

## An example program

This `sh` program implements the whole protocol against nothing (it invents values). It is a
starting point for a real integration, not something to install.

```sh
#!/bin/sh
# Example credential provider. Replace the echo lines with calls to the real system.
action="$1"
input="$(cat)"
request_id="$(printf '%s' "$input" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')"

# Exit 2 when the program has not been given what it needs.
[ -n "$API_TOKEN" ] || { echo "API_TOKEN is not set" >&2; exit 2; }

case "$action" in
  describe)
    cat <<'JSON'
{"protocol":1,"name":"Example client","description":"A client id and secret.",
 "fields":[{"key":"client_id","label":"Client ID","secret":false},
           {"key":"client_secret","label":"Client secret","secret":true}],
 "actions":["issue","revoke","health"]}
JSON
    ;;
  health)
    printf '{"ok":true,"message":"reachable"}\n'
    ;;
  issue)
    secret="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '{"external_id":"ex-%s","fields":{"client_id":"client-%s","client_secret":"%s"}}\n' \
      "$request_id" "$request_id" "$secret"
    ;;
  revoke)
    # Call the real system here; exit 0 if it is already gone.
    exit 0
    ;;
  *)
    echo "unknown action: $action" >&2
    exit 64
    ;;
esac
```

Install it by placing it in `scripts/credentials/` (or a `CREDENTIAL_SCRIPTS_DIR`), marking it
executable, then adding a provider that chooses it.
