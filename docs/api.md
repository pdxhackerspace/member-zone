# Member Zone API guide

The Member Zone API lets scripts, devices, and integrations do what members and staff do on the website. This guide explains how it works and walks through each task. The full reference — every endpoint, field, and error — is the OpenAPI document at `/api/v1/openapi.json`, rendered for people at `/api/docs`. Language models can start at `/llms.txt`.

All paths below are relative to `https://<your Member Zone>/api/v1`.

## Tokens

Every request carries an API token in the `Authorization` header:

```
Authorization: Bearer mz_3q2T…
```

No other way of sending it is accepted — not a query parameter, not a cookie. Being signed in to the website does not authenticate API requests.

There are two kinds of token:

- **Personal tokens** belong to a member, who creates them under **API tokens** on their dashboard. A personal token acts as that member: calls under `/me/…` are about them, implicitly.
- **Service-account tokens** belong to a service account — a kiosk, a printer, an integration — and are created by staff under **Settings → API tokens**. They outlive whoever set them up. A service-account token acts *for* members, so requests name the member (`member_ids`, or `rfid`/`username`/`email` for a kiosk).

A token is shown once, when it is created. Member Zone stores only a digest of it.

### Checking a token

`GET /me` describes the token making the request — a good first call when configuring a client:

```bash
curl -H "Authorization: Bearer $TOKEN" https://members.example.org/api/v1/me
```

```json
{
  "data": {
    "id": 12,
    "name": "Parking script",
    "hint": "x9Qa",
    "kind": "personal",
    "scopes": ["parking.own_permits"],
    "effective_scopes": ["parking.own_permits"],
    "expires_at": "2027-10-14T17:00:00Z",
    "holder": { "id": 42, "name": "Ada Lovelace", "username": "ada", "email": "ada@example.org", "active": true }
  }
}
```

### Scopes

A token's **scopes** are Member Zone privilege keys, chosen when the token is created. A request succeeds only if

1. the token has the scope the operation needs (each operation in the reference lists it under `x-required-scope`), **and**
2. the token's holder has that privilege right now.

So a token can never do more than its scopes, nor more than its holder. If the holder loses a role, every token they hold loses it too, immediately; `effective_scopes` in `GET /me` shows what still works. Administrators get no shortcut: an administrator's token is limited to its scopes like anyone's.

| Scope | Lets a token… |
| --- | --- |
| `parking.own_permits` | manage its holder's own parking permits, as a member can on the website. Every active member holds it. Personal tokens only. |
| `parking.manage_notices` | issue, change, clear, and print any parking permit or ticket. |
| `parking.clear_admin_required` | clear notices flagged as needing staff clearance (alongside `parking.manage_notices`). |
| `parking.issue_for_members` | issue a permit for the member who badges in at a kiosk. |
| `api.users.search` | look members up by name, username, or email. |
| `members.view_profile` | include members with private profiles in lookups (alongside `api.users.search`). |

### Lifetime, renewal, and suspension

Tokens expire — by default a year after they are created or last extended; staff can change the maximum. Whoever looks after a token (its holder, or a service-account token's contact) is emailed two weeks before it expires. **Extending** a token pushes its expiry out again and keeps the same secret, so nothing using it needs to change — even if it has already expired.

A **suspended** token is refused until it is resumed. A **revoked** token is gone for good. A token whose holder is no longer an active member is refused while they are inactive, and works again if they come back.

All of these get the same answer, deliberately without saying which:

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="Member Zone", error="invalid_token"

{"error": {"code": "invalid_token", "message": "The access token is missing, invalid, or no longer active.", "details": {}}}
```

## Requests and responses

- Send JSON bodies with `Content-Type: application/json`. Photo uploads are `multipart/form-data`.
- Successful responses wrap the result in `data`. Lists add `meta` with `page`, `per_page`, and `total`.
- Times are ISO 8601 in UTC: `2026-10-21T17:00:00Z`.
- Lists take `page` (from 1) and `per_page` (1–100, default 25), and send RFC 8288 `Link` headers with `first`, `prev`, `next`, and `last`.
- `PATCH` changes only the fields you send. `PUT` is accepted as a synonym.
- Each token may make 120 requests a minute, and each client address 600; beyond that you get `429` with `Retry-After`.

### Errors

Every error has the same shape:

```json
{"error": {"code": "validation_failed", "message": "Expires at must be within 2 weeks", "details": {"fields": {"expires_at": ["must be within 2 weeks"]}}}}
```

`code` is stable and meant for programs; `message` is for people.

| Status | `code` | Meaning |
| --- | --- | --- |
| 400 | `bad_request` | A parameter is missing or not one of the allowed values. |
| 401 | `invalid_token` | See above. |
| 403 | `insufficient_scope` | The token lacks the operation's scope, or its holder lacks the privilege. `details.required_scope` names it. |
| 403 | `forbidden` | The token may use the operation, but not here: a ticket a member can't edit, a notice needing staff clearance, a service-account token on a `/me` endpoint. |
| 404 | `not_found` | No such record, or not one this token may see. |
| 409 | `conflict` | The record is not in a state that allows this: already cleared, not active, already requested. |
| 422 | `validation_failed` | The record could not be saved. `details.fields` maps each field to its problems. |
| 422 | `ineligible_member` | The member cannot have a permit (kiosk requests). |
| 429 | `rate_limited` | Slow down. |
| 502 | `print_failed` | The printer did not accept the job. |

## Parking permits and tickets

A **permit** says a project may stay in the space until it expires; a **ticket** says one was left without a permit. Notices are `active`, then `expired` once their time is up, and `cleared` when the project is gone. Every change is recorded in the notice's history (`events`), marked `via_api` when it came through the API.

### Your own permits (personal tokens, `parking.own_permits`)

These are the same rules as the website's **Project parking permit** pages: a permit you create is at most two weeks long and always has you on it, and you may change permits but not tickets.

List what you have:

```bash
curl -H "Authorization: Bearer $TOKEN" "https://members.example.org/api/v1/me/parking/notices?status=active"
```

Give yourself a permit:

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"description": "Bookshelf glue-up", "location": "Woodshop", "location_detail": "Bench B",
       "expires_at": "2026-10-21T17:00:00Z"}' \
  https://members.example.org/api/v1/me/parking/notices
```

Add `"member_ids": [57]` to put someone else on it too (anyone whose profile you can see). Find ids with `GET /members?q=` if your token has `api.users.search`.

Extend it, add a note, then clear it when you're done:

```bash
curl -X PATCH -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"expires_at": "2026-10-25T17:00:00Z"}' https://members.example.org/api/v1/me/parking/notices/501
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"note": "Clamps off Thursday"}' https://members.example.org/api/v1/me/parking/notices/501/notes
curl -X POST -H "Authorization: Bearer $TOKEN" https://members.example.org/api/v1/me/parking/notices/501/close
```

If a notice is flagged as needing staff clearance, `close` answers `403 forbidden`; ask staff instead with `POST /me/parking/notices/{id}/request_clearance`.

### Staff (`parking.manage_notices`)

Staff and service accounts reach every notice under `/parking/notices`, and name members by id:

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"notice_type": "ticket", "description": "Unattended 3D print", "location": "Electronics Lab",
       "expires_at": "2026-10-17T17:00:00Z", "member_ids": [42]}' \
  https://members.example.org/api/v1/parking/notices
```

A permit needs at least one member; a ticket may be for nobody yet. Members on a new notice, and members added later, are emailed. On `PATCH`, sending `member_ids` replaces the list; leaving it out keeps it. Filter lists with `type`, `status`, and `member_id`.

Clearing a notice flagged `requires_admin_clearance` also needs `parking.clear_admin_required` on the token.

### Photos

Upload up to 10 images at a time, each under 15 MB, in a `photos[]` field:

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -F "photos[]=@bench.jpg" -F "photos[]=@label.jpg" \
  https://members.example.org/api/v1/parking/notices/501/photos
```

Each photo in a notice has a `download_path`; fetch it with the same token. `DELETE` that path to remove it. Members can add and remove photos on their own permits under `/me/parking/notices/{id}/photos`.

### PDFs and printing

`GET …/notices/{id}/pdf` returns the notice as a PDF. To print, pick a printer from `GET /parking/printers` and send its id:

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"printer_id": 3}' https://members.example.org/api/v1/parking/notices/501/print
```

Thermal receipt printers get a narrow layout; add `"layout": "letter"` for a full page. Only active notices print (`409` otherwise), and a printer that refuses the job gives `502 print_failed`.

### Kiosks (`parking.issue_for_members`)

An access control device acts for the member who badges in. Set it up with a service account holding a role that confers `parking.issue_for_members`, and a token with that scope. Then:

```bash
curl -X POST -H "Authorization: Bearer $KIOSK_TOKEN" -H "Content-Type: application/json" \
  -d '{"rfid": "0012345678", "mode": "blank"}' \
  https://members.example.org/api/v1/parking/permit_requests
```

Identify the member with exactly one of `rfid`, `username`, or full `email`.

- `"mode": "link"` emails the member a 12-hour link to a form where they fill in and print the permit. Nothing is created until they submit it.
- `"mode": "blank"` issues a two-week permit at once for them to hand-write, and emails a link to record the details online.

The response gives the member's name and, for a blank permit, its id and expiry — enough to print a slip. It never includes the form link.

## Members (`api.users.search`)

```bash
curl -H "Authorization: Bearer $TOKEN" "https://members.example.org/api/v1/members?q=ada"
```

Matches part of a name, username, or alias, or a whole email address (email is stored encrypted, so it only matches in full). Up to 20 results. Members with private profiles are left out unless the token also has `members.view_profile`. `GET /members/{id}` fetches one.
