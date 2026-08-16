# MemberZone

![CI](https://github.com/pdxhackerspace/member-manager/actions/workflows/ci.yml/badge.svg)
![Staging image](https://github.com/pdxhackerspace/member-manager/actions/workflows/staging.yml/badge.svg)
![Production image](https://github.com/pdxhackerspace/member-manager/actions/workflows/production.yml/badge.svg)
![Version](https://img.shields.io/github/v/release/pdxhackerspace/member-manager?label=version)
![Ruby](https://img.shields.io/badge/Ruby-3.3.11-red?logo=ruby)
![Rails](https://img.shields.io/badge/Rails-8.1-red?logo=rubyonrails)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-blue?logo=postgresql)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

MemberZone is a Rails application that keeps a local roster synchronized with an Authentik group. Users authenticate via Authentik (OpenID Connect), and the application periodically (or on-demand) refreshes the local database using the Authentik API.

## Requirements

- Ruby 3.3.11 (see `.ruby-version`)
- Rails 8.1
- PostgreSQL 16+
- Redis 7+ (Sidekiq, Action Cable)
- Node.js (only for asset builds when running locally)
- Yarn

You can also run everything via Docker/Docker Compose (see below).

## Getting Started

```bash
bundle install
bin/rails db:prepare
bin/dev # starts Rails + CSS watcher
```

### Environment Variables

Set these variables in your shell, `.env`, or Docker Compose environment:

| Variable | Description |
| --- | --- |
| `APP_BASE_URL` | Public URL of the app (used by OmniAuth), e.g. `http://localhost:3000` |
| `GITHUB_REPOSITORY_URL` | Optional URL for the GitHub link in the page footer; omit to hide it |
| `MEMBER_ZONE_BASE_URL` | Public base used to build incoming webhook URLs. Formerly `MEMBER_MANAGER_BASE_URL`, which is still read as a fallback |
| `AUTHENTIK_ISSUER` | Issuer URL from the Authentik application (ends with `/application/o/<slug>/`) |
| `AUTHENTIK_CLIENT_ID` / `AUTHENTIK_CLIENT_SECRET` | OAuth credentials from Authentik |
| `AUTHENTIK_REDIRECT_URI` | Callback URL registered in Authentik (default `http://localhost:3000/auth/authentik/callback`) |
| `AUTHENTIK_API_BASE_URL` | Base URL for Authentik's API (defaults to the issuer) |
| `AUTHENTIK_API_TOKEN` | Service account API token sent as `Authorization: Bearer` (required at boot in non-test environments) |
| `AUTHENTIK_GROUP_ID` | UUID/slug of the Authentik group to sync |
| `AUTHENTIK_GROUP_PAGE_SIZE` | Optional page size override when fetching group members (default 200) |
| `SLACK_API_TOKEN` | Slack Bot/User OAuth token with at least `users:read` scope |
| `DB_HOST`, `DB_USERNAME`, `DB_PASSWORD`, `DB_PORT` | Database connection settings |
| `DATABASE_URL` | Optional full PostgreSQL URL (overrides the individual DB vars) |
| `LOCAL_AUTH_ENABLED` | Set to `true` to enable local (database) accounts |
| `LOCAL_AUTH_EMAIL`, `LOCAL_AUTH_PASSWORD`, `LOCAL_AUTH_FULL_NAME` | (Optional) Default credentials to seed a test admin account |
| `GOOGLE_SHEETS_CREDENTIALS` | JSON for a Google service account with Sheets read access |
| `GOOGLE_SHEETS_ID` | Spreadsheet ID of the roster workbook |
| `PAYPAL_CLIENT_ID` / `PAYPAL_CLIENT_SECRET` | PayPal REST credentials for the reporting API |
| `PAYPAL_API_BASE_URL` | Optional override (defaults to `https://api-m.paypal.com`) |
| `PAYPAL_TRANSACTIONS_LOOKBACK_DAYS` | Days of history to pull during sync (default 30) |
| `RECHARGE_API_KEY` | Recharge API access token |
| `RECHARGE_API_BASE_URL` | Optional override (defaults to `https://api.rechargeapps.com`) |
| `RECHARGE_TRANSACTIONS_LOOKBACK_DAYS` | Days of Recharge history to pull during sync (default 30) |
| `DATABASE_FIELD_ENCRYPTION_KEY` | Key for encrypting personal data and credentials at rest — see [docs/encrypted-fields.md](docs/encrypted-fields.md) |
| `EMAIL_LOOKUP_HMAC_KEY` | Key for deriving the email lookup digests that make encrypted addresses searchable |

## Docker & Compose

The repository ships **four** Compose files so local stacks stay predictable and Postgres instances do not clash with other projects on the same machine. Each stack sets a Compose **project name** (`name:`) so volumes are isolated. Postgres containers use fixed **container names** prefixed with `memberzone-`.

| File | Use when | Postgres |
| --- | --- | --- |
| [`docker-compose.dev.yml`](docker-compose.dev.yml) | Day-to-day local development (`web`, Sidekiq, live-mounted source). | Included. Container: `memberzone-dev-postgres`, published on **localhost:5432**. |
| [`docker-compose.test.yml`](docker-compose.test.yml) | Running the test suite from Docker (prebuilt `member_zone_web:latest`, fast reruns with bind-mounted code). | Included. Container: `memberzone-test-postgres`, published on **localhost:5433** (so dev can use 5432 at the same time). Redis: `memberzone-test-redis`, **localhost:6380**. |
| [`docker-compose.test.build.yml`](docker-compose.test.build.yml) | Same as test stack but **builds** the app image first (use after Dockerfile changes or to create the image the first time). | Same Postgres/Redis as `docker-compose.test.yml`. |
| [`docker-compose.lint.yml`](docker-compose.lint.yml) | RuboCop only (prebuilt `member_zone_rubocop:latest`, bind-mounted source). | Not required. RuboCop is static and does not use PostgreSQL. |
| [`docker-compose.lint.build.yml`](docker-compose.lint.build.yml) | Same as lint stack but **builds** the dedicated RuboCop image first. | Not required. |
| [`docker-compose.server.yml`](docker-compose.server.yml) | Production- or staging-style runs (image-based app, no source mount). | **Not included.** Point `DATABASE_URL` (or `DB_HOST` and related variables) at an existing PostgreSQL server. Redis defaults to the bundled `redis` service; set `REDIS_URL` to use an external instance. |

### Local development

```bash
docker compose -f docker-compose.dev.yml up --build
```

Apply migrations (one-off):

```bash
docker compose -f docker-compose.dev.yml --profile tools run --rm migrate
```

The app is at [http://localhost:3000](http://localhost:3000). Configure `.env` (see `.env.development.example`); Compose still injects `DB_HOST=db` and `REDIS_URL` for services in this file.

### Restoring a backup into dev

```bash
bin/dev-db-restore ~/Downloads/backup-mm.sql
```

Drops and recreates `member_zone_development`, loads the backup, applies any migrations the backup predates, and creates the local sign-in account from `LOCAL_AUTH_EMAIL` / `LOCAL_AUTH_PASSWORD`. Accepts pg_dump custom-format archives (whatever the file is named), plain SQL, and gzipped SQL.

That last step matters: production authenticates through Authentik, so its backups contain no `local_accounts` rows and there is no way to sign in to a freshly restored copy. Running `db:seed` would also create the account, but it seeds training topics and other defaults on top of the production data — use this script instead.

If local sign-in stops working without the account changing, the field-encryption keys probably did. Email addresses are encrypted at rest and looked up through a keyed digest (see [docs/encrypted-fields.md](docs/encrypted-fields.md)), so setting or changing `DATABASE_FIELD_ENCRYPTION_KEY` / `EMAIL_LOOKUP_HMAC_KEY` leaves every existing account unfindable. Rebuild one without reloading the database:

```bash
docker compose -f docker-compose.dev.yml exec web bin/rails local_auth:provision
docker compose -f docker-compose.dev.yml exec web bin/rails local_auth:prune_unreadable   # PRUNE=1 to delete
```

Backups are produced by a pg_dump 18 client, whose custom-format archives the PostgreSQL 16 server cannot read directly — `pg_restore` fails with `unsupported version (1.16) in file header`. The script reads the archive with an 18 client container and pipes plain SQL into the dev server, so restore it with this rather than calling `pg_restore` against the `db` container.

### Tests (Docker)

Default workflow uses a thin test image and bind-mounts the repo at `/rails`. Gems are installed at container startup into a named Docker volume, so repeat runs reuse the previous bundle unless `Gemfile.lock` changed. Each test run recreates and reloads the test database before running the requested command.

Build or refresh the image when `Dockerfile.test` or base system dependencies change, or the first time on a machine:

```bash
docker compose -f docker-compose.test.build.yml build test
```

Then run tests (repeat as often as you like):

```bash
docker compose -f docker-compose.test.yml run --rm test
# Single file:
docker compose -f docker-compose.test.yml run --rm test bin/rails test test/models/member_test.rb
```

To run tests **after** forcing a test image rebuild in one shot:

```bash
docker compose -f docker-compose.test.build.yml run --rm test
```

### Lint (Docker)

Same pattern: use a prebuilt `member_zone_rubocop:latest` for quick runs. Build or refresh when RuboCop versions change:

```bash
docker compose -f docker-compose.lint.build.yml build rubocop
docker compose -f docker-compose.lint.yml run --rm rubocop
```

One-shot lint with a fresh image build:

```bash
docker compose -f docker-compose.lint.build.yml run --rm rubocop
```

### Server / staging-style

Provide production secrets and database URL in `.env` (or the host environment), then:

```bash
docker compose -f docker-compose.server.yml up -d --build
docker compose -f docker-compose.server.yml --profile tools run --rm migrate
```

Optional: set `WEB_PORT` to publish the app on a different host port (default `3000`).

### Shell aliases (optional)

To avoid repeating `-f`, add to your shell profile, for example:

```bash
alias dcdev='docker compose -f docker-compose.dev.yml'
alias dctest='docker compose -f docker-compose.test.yml'
alias dctestbuild='docker compose -f docker-compose.test.build.yml'
alias dclint='docker compose -f docker-compose.lint.yml'
alias dclintbuild='docker compose -f docker-compose.lint.build.yml'
alias dcserver='docker compose -f docker-compose.server.yml'
```

## Authentik Integration

- **API access** uses a static Bearer token from `AUTHENTIK_API_TOKEN` (service account token in Authentik). It is not read from the database and there is no OAuth2 refresh flow for API calls.
- OpenID Connect login is configured via OmniAuth (`/auth/authentik`).
- User sessions are persisted in the local database. The first successful login will create/refresh the corresponding `User` record.
- To synchronize an Authentik group into the database, use:
  - The **Sync now** button on the Users page.
  - `rails authentik:sync_users`
  - `Authentik::GroupSyncJob.perform_later`

The sync job fetches all members of the configured group, updates existing users, creates new ones, and deactivates local users no longer in Authentik.
Member records also capture the raw Authentik `attributes` payload in a searchable `authentik_attributes` JSON column (GIN indexed). Query helper example:

```ruby
User.with_attribute(:department, "Engineering")
```

### Admin Status Configuration

To set admin status for users based on Authentik group membership, create a Property Mapping in Authentik:

1. Go to **Customization** → **Property Mappings** → **Create**
2. Type: **OAuth/OpenID Scope Mapping**
3. Name: "Member Zone Admin Status"
4. Expression:
   ```python
   # Check if user is in the "admins" group (replace "admins" with your group name)
   admin_group = "admins"
   is_in_admin_group = any(group.name == admin_group for group in user.ak_groups.all())
   
   return {
       "is_admin": is_in_admin_group
   }
   ```
5. Assign this property mapping to your OAuth provider:
   - Go to **Applications** → **Providers** → your Member Zone provider
   - Add the property mapping to **Property Mappings** or **Scopes**

Users in the specified group will have `is_admin` set to `true` when they log in. The application looks for the `is_admin` claim in the OAuth token.

## Slack Integration

Set `SLACK_API_TOKEN` (bot or user token with `users:read`) to enable Slack syncing. Then run:

```bash
rails slack:sync_users
```

This job calls `users.list`, follows pagination cursors, and mirrors each member into the `slack_users` table (including admin flags, time zone, profile info, and a searchable `raw_attributes` JSONB column backed by a GIN index). Example query:

```ruby
SlackUser.active.with_attribute(:department, "IT")
```

## RFID Sign-In

The login page exposes a **Sign in via RFID** form. Scanning/entering a value that matches any RFID in a user's `rfid` array (populated via sheet sync or manual editing) on an active user signs that person in immediately—handy for badge readers or kiosk setups.

## Google Sheet Intake

Provide `GOOGLE_SHEETS_CREDENTIALS` (the full JSON for a service account key) and `GOOGLE_SHEETS_ID` (from the sheet URL). Then run:

```bash
rails google_sheets:sync
```

The sync job pulls both the **Member List** and **Access** tabs, normalizes their columns, and merges them into the `sheet_entries` table. Member/Access rows are matched by email (falling back to name) so that access permissions end up on the same record. Each row's original data is retained in `SheetEntry#raw_attributes` for advanced filtering or auditing. Browse the current import inside the app under **Sheet Entries** (navbar) for a searchable list plus detailed drill-down.

## PayPal Payments

Provide `PAYPAL_CLIENT_ID` / `PAYPAL_CLIENT_SECRET` (and optionally override `PAYPAL_API_BASE_URL`). Then run:

```bash
rails paypal:sync_payments
```

The sync job calls PayPal’s Transaction Reporting API for the configured lookback window, stores each payment in the `paypal_payments` table (including raw JSON), and exposes them under **PayPal Payments** in the UI with quick totals, detail pages, and a “Sync now” button. Payments automatically link to Authentik users and Sheet entries when the payer email matches, so each profile page now shows its payment history as well.

## Recharge Payments

Set `RECHARGE_API_KEY` (and optionally override the base URL/lookback days) to enable Recharge syncing, then run:

```bash
rails recharge:sync_payments
```

The sync job pulls recent charges from Recharge, records them in `recharge_payments`, and surfaces them inside the app under **Recharge Payments** plus in each Authentik/Sheet profile’s payment history (alongside PayPal results).

## Roles and Privileges

Privileges bundle into roles, roles attach to training topics, and holding a topic confers that topic's roles. Members are never granted privileges directly. `is_admin` remains a superuser bypass, so a misconfigured role cannot lock administrators out.

Roles are configuration rather than data, so they can be moved between instances as JSON. **Settings → Roles → Import / export** does it in the browser, and the same thing is available from the command line:

```bash
rails roles:export ROLES_FILE=roles.json
rails roles:import ROLES_FILE=roles.json MODE=replace
```

The document keys everything by name and privilege key rather than by database id. `MODE=merge` (the default) only ever adds; `MODE=replace` makes the listed privileges and topic attachments the whole truth for the roles named. Add `DRY_RUN=1` to report what would change without writing it. An import runs in a single transaction, cannot create privileges outside the catalog or training topics that do not exist, and cannot delete roles — unrecognized entries are reported and skipped.

`db/role_definitions/director_roles.json` configures the three director training topics to confer what they conferred before roles existed. Apply it with `MODE=replace`, then detach the seeded `Application approver` and `Application reviewer` bundles from those topics so they stop conferring alongside the imported roles.

Every key in `Privilege::CATALOG` is now enforced somewhere, and `test/models/privilege_catalog_coverage_test.rb` fails if one is added with nothing reading it. Which key governs which page is documented in `docs/ui-privilege-visibility.md`; the navbar and the settings hub filter themselves to what the signed-in account holds, so a holder reaches their pages without knowing the URL.

Two rules govern where a privilege may be added. On administrator pages a privilege is what lets you in, and converting a page to one cannot narrow access, because `is_admin?` bypasses every check. **On member-facing pages a privilege is added with `||`, never `&&`** — access there flows from a data relationship (you are trained in the topic, the notice is yours), and an `&&` would take a member's own materials away from them.

`Role::DEFAULT_ROLES` only seeds roles into a database that does not already have them, so a shipped role that gains a privilege never reaches an existing install. Backfill those:

```bash
rails roles:backfill_seeds DRY_RUN=1   # report
rails roles:backfill_seeds             # apply
```

It only ever adds, and only to roles that already exist under their seeded name — privileges an administrator removed stay removed, and roles they renamed or created are left alone.

### Local Test Accounts

Local accounts are intended for development or emergency access when Authentik is unavailable:

1. Set `LOCAL_AUTH_ENABLED=true` in your environment.
2. (Optional) Provide `LOCAL_AUTH_EMAIL` / `LOCAL_AUTH_PASSWORD` / `LOCAL_AUTH_FULL_NAME` so `bin/rails db:seed` can create a bootstrap admin.
3. Visit `/login` and use the **Sign in locally** form. Successful local logins still create a matching `User` record so the rest of the app behaves the same way.

## Tests

```bash
bin/rails test
```

With Docker (includes dedicated Postgres and Redis):

```bash
docker compose -f docker-compose.test.yml run --rm test
```

Stimulus controllers with logic worth pinning down have Node tests under `test/javascript/`,
run against jsdom. CI runs these alongside the Rails suite:

```bash
yarn test:js
```

## Next Steps

- Configure a scheduler (cron/ActiveJob) to run `Authentik::GroupSyncJob` periodically.
- Deploy using the provided Dockerfile or your preferred Rails hosting platform.
