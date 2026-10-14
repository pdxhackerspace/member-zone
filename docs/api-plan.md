# Member Zone API — implementation plan

Branch: `feature/api` (off `staging`). Status: in progress — see the PR sequence in section 10.

## Goals

- Programmatic access to Member Zone over HTTPS, authenticated with bearer tokens.
- Tokens are issued, extended, suspended, and revoked; their scopes are privilege keys.
- The API is documented once, in a form that humans, code generators, and LLMs can all read.
- First area: parking permits and tickets, including photos and printing.
- `WebhookDevice` and its endpoint are removed; access control kiosks become service-account API clients.

## Decisions

| Topic | Decision |
| --- | --- |
| Transport | `Authorization: Bearer <token>` only. No cookie/session auth on `/api/v1`, no query-param or custom-header tokens. |
| Token holder | Every token belongs to a `User`: a member (personal token) or a service account (`users.service_account`). A service-account token survives its creator leaving. |
| Issuing | Members create personal tokens for themselves. Service-account tokens are managed by holders of `api.tokens.manage`. No cap on active tokens. |
| Scopes | A subset of `Privilege::CATALOG` keys the holder currently has. Global-scoped privileges only in v1; topic-scoped privileges are rejected as scopes until an API needs them. |
| Effective authority | Token scopes **∩** the holder's privileges *at request time*. Losing a role shrinks every token at once. `is_admin?` does not widen a token past its scopes. |
| Holder inactive | Token is rejected as invalid while the holder is inactive (members: `effective_membership_state`, so elapsed deadlines count before the 4 AM tick; service accounts: `active`). It works again if the holder becomes active again. |
| Temporary disable | Suspend / resume. |
| Permanent disable | Revoke. Irreversible. |
| Lifetime | Every token has `expires_at` ≤ now + `DefaultSetting.api_token_max_lifetime_days` (default 365). Extending sets `expires_at = now + max`; extensions do not stack. Changing the setting affects new tokens and extensions only. |
| Lapsed tokens | An expired token can be extended and keeps its secret, so clients need no reconfiguration. Revoked tokens cannot. |
| Expiry reminders | New `ReminderSetting` entry `api_token_expiry`, anchored on `expires_at`. Not opt-out-able. |
| Reminder recipient | Each token has a **responsible contact** (defaults to the creator, reassignable). If the contact is inactive, reminders go to every `api.tokens.manage` holder, and the admin list flags the token. |
| Errors | One JSON envelope; every invalid-token cause returns the same 401. Detail goes to the log only. |
| Acting on behalf | Personal token: parking calls act for the holder; `member_id` is ignored. Service-account token: `member_id` is required where a member is the subject. |

## 1. Data model

### `api_tokens`

| Column | Notes |
| --- | --- |
| `user_id` (fk, not null) | The holder: member or service account. |
| `contact_user_id` (fk, not null) | Responsible contact for reminders. |
| `created_by_id` (fk, not null) | |
| `name` (not null) | Human label, e.g. "Front door kiosk". |
| `description` | |
| `token_digest` (unique, not null) | SHA-256 of the secret. Plaintext shown once. |
| `token_hint` | Last 4 characters. |
| `scopes` (string[], not null, default `{}`) | GIN-indexed. |
| `expires_at` (not null, indexed) | |
| `suspended_at`, `suspended_by_id`, `suspended_reason` | |
| `revoked_at` (indexed), `revoked_by_id`, `revoked_reason` | |
| `last_extended_at` | |
| `last_used_at`, `last_used_ip` | Updated at most once a minute per token. |

Token format: `mz_` + `SecureRandom.urlsafe_base64(32)`. The prefix makes leaks detectable by secret scanners.

### `ApiToken` model

- `ApiToken.authenticate(raw)` → token or nil. Digest lookup (like `WebhookDevice` today), then: not revoked, not suspended, not expired, holder active.
- `#allows?(key, user:)` → `scopes.include?(key) && user.privilege_conferred?(key)`. The admin bypass is deliberately not used here.
- `#extend!(by:)`, `#suspend!(by:, reason:)`, `#resume!(by:)`, `#revoke!(by:, reason:)`, `#record_use!(ip:)`.
- Validations: every scope is a global key in the catalog; on create/scope change, the issuer must hold each scope (so must the holder); `expires_at` within the max lifetime.
- `#state` → `active` / `suspended` / `expired` / `revoked` (for UI; not exposed by the 401 path).
- Each lifecycle change writes a journal entry on the holder.

### Elsewhere

- `DefaultSetting.api_token_max_lifetime_days` (integer, not null, default 365).
- New privileges in `Privilege::CATALOG`:
  - `api.tokens.manage`: manage service-account tokens and see all tokens.
  - `parking.own_permits`: self-service permits. Treated as held by every active, non-service-account member, so it doesn't need a role.
  - `parking.issue_for_members`: the kiosk flow (look up a member by badge/username/email and issue a permit or link for them).
- `ApiToken` gets a category in the privilege editor ("API").

## 2. Request pipeline

`Api::V1::BaseController < ActionController::API`:

- `before_action :authenticate_token!`: parses the bearer header, calls `ApiToken.authenticate`, sets `current_api_token` and `current_user` (also `true_user`; impersonation never applies).
- `require_scope!(key)`: 403 `insufficient_scope` naming the key if the token lacks it.
- `rate_limit` per token via `RateLimiting.store` (default 120/minute; 429 with `Retry-After`).
- `Current.api_token` set for the request so models and journal entries can record "via API token #N".
- Errors:

  ```json
  { "error": { "code": "invalid_token", "message": "…", "details": {} } }
  ```

  | Status | `code` | When |
  | --- | --- | --- |
  | 401 | `invalid_token` | missing, malformed, unknown, revoked, suspended, expired, holder inactive (plus `WWW-Authenticate: Bearer error="invalid_token"`) |
  | 403 | `insufficient_scope` | scope missing or holder lacks the privilege |
  | 403 | `forbidden` | record-level rule (e.g. clearance authority) |
  | 404 | `not_found` | |
  | 422 | `validation_failed` | `details` holds field errors |
  | 429 | `rate_limited` | |

- Pagination: `?page=&per_page=` (max 100), with `meta: { page, per_page, total }` and a `Link` header.
- JSON via Jbuilder partials under `app/views/api/v1/`; timestamps ISO 8601 UTC.
- `PrivilegeCoverageTest` learns that `Api::V1::*` actions are covered by `authenticate_token!` + `require_scope!` (it should assert every v1 action calls `require_scope!`, not merely authenticate).

## 3. Shared parking services

The HTML controllers held the parking rules. Before adding API controllers, they move into services under `app/services/parking_notices/` that both front ends call:

- `ParkingNotices::Issue`: staff issue (permit or ticket), or self-service (`self_service: true`: permit only, capped at `MAX_SELF_SERVICE_DURATION`, issuer always on it). Journal entry and notifications.
- `ParkingNotices::Update`: details and, when given, the member list (`members_removable_by?` for self-service); notifies newly added members.
- `ParkingNotices::Clear` / `ParkingNotices::RequestClearance`: `clearable_by?` and the staff-clearance path.
- `ParkingNotices::AddNote`, `ParkingNotices::Print`.
- `ParkingNotices::MemberResolution`, `ParkingNotices::SelfServiceDuration`: the rules formerly in controller concerns.
- Photo services (`AttachPhotos`, `RemovePhoto`) arrive with the API endpoints that need them.
- `ParkingPermits::DeviceIssuer` keeps its logic; it takes an `api_token:` instead of `device:`.

Each returns a `ParkingNotices::Result` (`success?`, `notice`, `error` symbol, `newly_added`, `job_id`, `message`) that HTML controllers turn into redirects and API controllers turn into JSON. This step ships alone and changes no behaviour.

## 4. Endpoints (v1)

### Identity

| Method & path | Scope | Notes |
| --- | --- | --- |
| `GET /api/v1/me` | none (any valid token) | Holder, token name, scopes, `expires_at`. |

### Members

| Method & path | Scope | Notes |
| --- | --- | --- |
| `GET /api/v1/members?q=` | `api.users.search` | Same matching and `MemberVisibility` rules as the existing picker; exact email via the lookup digest. |

### Parking: staff (any notice)

Scope `parking.manage_notices`. Service accounts pass `member_ids` explicitly.

| Method & path | Notes |
| --- | --- |
| `GET /api/v1/parking/notices` | Filters: `type`, `status`, `member_id`. Paginated. |
| `POST /api/v1/parking/notices` | Permit or ticket. |
| `GET /api/v1/parking/notices/:id` | Includes events and photo metadata. |
| `PATCH /api/v1/parking/notices/:id` | |
| `POST /api/v1/parking/notices/:id/clear` | Also needs `clearable_by?`. |
| `POST /api/v1/parking/notices/:id/notes` | |
| `POST /api/v1/parking/notices/:id/photos` | Multipart; existing content-type/size validations. |
| `DELETE /api/v1/parking/notices/:id/photos/:photo_id` | |
| `GET /api/v1/parking/notices/:id/pdf` | `application/pdf`. |
| `POST /api/v1/parking/notices/:id/print` | Body: `printer_id`, optional `force_letter`. |
| `GET /api/v1/parking/printers` | Scope `parking.manage_notices` or `parking.own_permits`. |

Photo metadata includes a short-lived signed download URL.

### Parking: self-service (holder's own notices)

Scope `parking.own_permits`. Personal tokens only; a service-account token gets 403.

| Method & path | Notes |
| --- | --- |
| `GET /api/v1/me/parking/notices` | The holder's permits and tickets. |
| `POST /api/v1/me/parking/permits` | 2-week cap. |
| `GET /api/v1/me/parking/notices/:id` | |
| `PATCH /api/v1/me/parking/permits/:id` | Own permits only. |
| `POST /api/v1/me/parking/notices/:id/close` | Or 403 pointing at `request_clearance`. |
| `POST /api/v1/me/parking/notices/:id/request_clearance` | |
| `POST /api/v1/me/parking/notices/:id/notes` | |
| `POST /api/v1/me/parking/permits/:id/photos`, `DELETE …/photos/:photo_id` | |
| `GET /api/v1/me/parking/permits/:id/pdf`, `POST …/print` | |

### Parking: kiosk flow (replaces the device webhook)

| Method & path | Scope | Notes |
| --- | --- | --- |
| `POST /api/v1/parking/permit_requests` | `parking.issue_for_members` | Body: one of `rfid` / `username` / `email`, plus `mode` (`link` or `blank`). Same responses as today's webhook: never returns the form link. |

## 5. Removing `WebhookDevice`

No devices are in production, so this is a straight removal:

- Migration: add `api_token_id` (fk, nullable, indexed, `on_delete: :nullify`) to `parking_notices` and `parking_permit_links`; drop `webhook_device_id` from both; drop `webhook_devices`. Reversible (the down path recreates the empty table and columns).
- Delete `WebhookDevice`, `WebhookDevicesController`, `DeviceWebhooksController`, their views, routes, settings-menu entry (`SettingsHelper`), and tests.
- Update `ParkingNoticeDeviceDetails`, `ParkingPermitLink`, `ParkingPermits::DeviceIssuer`, `ParkingPermits::LinkSubmission`, `Reminders::ParkingPermitDetailsEligibility`, `Reminders::NotifyParkingPermitDetails`, the reminder-settings view, and `PrivilegeCoverageTest` to refer to the issuing token.
- "Issued by" on a kiosk permit shows the service account and token name.

## 6. Token management UI

- **Profile → API tokens tab (members).** Create (name, scopes chosen from what you hold, plaintext shown once with a copy button), extend, suspend/resume, revoke, last used. Second-person copy.
- **Settings → API tokens (`api.tokens.manage`).** All tokens with filters (holder type, state, expiring soon, contact inactive). Create service-account tokens (pick or create the service account; set the contact). Same lifecycle actions on any token.
- Design system: status dot + `-subtle` badge for state, `.table-compact`, one `btn-primary` per region; revoke behind a confirm.
- Rake: `api_tokens:revoke_for_user[USER_ID]` and its `api_tokens:revoke_for_user_preview` twin.

## 7. Expiry reminders

- `ReminderSetting::CATALOG['api_token_expiry']`: anchor `expires_at`, `start_offset_days: -14`, `interval_days: 7`, `max_reminders: 3`, `allow_opt_out: false`, email template `api_token_expiry_reminder` (token name, hint, expiry, extend link).
- `Reminders::ApiTokenExpiryEligibility`: tokens not revoked, expiring within the window, holder active. `ReminderDelivery` subject is the token, so extending (moving the anchor) restarts the sequence.
- `Reminders::NotifyApiTokenExpiry` + `ApiTokenExpiryReminderJob`, cron daily at 8:15 AM in `config/initializers/sidekiq.rb` (`active_job: true`, no queue).
- Recipient: the contact if active, otherwise all `api.tokens.manage` holders. Delivery goes through `Notifications::DeliveryGate` as usual.

## 8. Documentation

- **`docs/api/openapi.yaml` (OpenAPI 3.1): the source of truth.** Every operation gets a summary, a plain-English description, the required scope (`x-required-scope` plus prose), request/response schemas, and examples, including error examples.
- Served at `GET /api/v1/openapi.json` (no auth).
- **`docs/api.md`: human guide.** Getting a token, auth, scopes, errors, pagination, acting for members vs. self, `curl` walkthroughs for each parking flow, the kiosk integration.
- **`/llms.txt`**: short markdown index linking the guide and spec (per the llms.txt convention), plus `/api/v1/llms-full.txt`, the guide and an endpoint reference flattened into one markdown file.
- **`/api/docs`**: rendered reference (a static page loading Scalar from a pinned CDN version, pointed at `openapi.json`).
- **Contract tests:** every `/api/v1` route has a spec operation and vice versa; request tests validate response bodies against the spec's schemas (adds `json_schemer`, test group only).
- `README.md` (architecture: API section) and `docs/USER_GUIDE.md` (managing tokens, reminders) updated.

## 9. Tests

- Model: `ApiToken` authentication for each invalid path (unknown, suspended, revoked, expired, inactive member, inactive service account, member reactivated); scope validation; extension rules; contact fallback.
- Request: each endpoint for 200/201, 401, 403 `insufficient_scope`, scope ∩ privilege narrowing (token has scope, holder lost role → 403), personal vs. service-account `member_id` handling, rate limit.
- Services: the extracted `Parking::*` services (existing controller tests keep passing unchanged).
- Reminders: eligibility, anchor restart on extension, contact fallback.
- Contract: spec ↔ routes ↔ responses.
- External calls (CUPS printing) stubbed.

## 10. PR sequence (each into `staging`)

1. **Parking services extraction.** No behaviour change.
2. **`ApiToken` + base controller + `/api/v1/me` + member lookup.** Includes the settings field, new privileges, the OpenAPI skeleton, and contract-test harness.
3. **Token management UI** (profile tab + settings page) **and expiry reminders.**
4. **Parking endpoints:** staff, self-service, photos, PDF, printing.
5. **Kiosk flow on the API; remove `WebhookDevice`.**
6. **Docs polish:** guide, `llms.txt`, rendered docs page, USER_GUIDE/README.

## Later (not in v1)

- Topic-scoped privileges as token scopes.
- Per-request API audit log.
- Webhooks *out* of Member Zone.
