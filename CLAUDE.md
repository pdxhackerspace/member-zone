# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MemberZone (directory is still named `MemberManager`) is a Rails 8.1 app that runs a makerspace/membership organization: member roster, membership applications, payments (PayPal, Recharge, Ko-fi, cash), training records, RFID building access, parking notices, incident reports, and messaging. Authentik (OIDC) is the identity provider; the local database is kept in sync with it in both directions.

Ruby 4.0.6, PostgreSQL 16, Redis 8, Sidekiq, Bootstrap 5.3 via cssbundling-rails, Stimulus/Turbo, importmap.

## Commands

Everything below has a Docker equivalent; Docker is the normal path because dev/test Postgres run on separate ports and images.

```bash
# Local (needs a local Postgres/Redis)
bin/dev                       # Rails server + `yarn watch:css` via foreman
bin/rails test                # full suite
bin/rails test test/models/user_test.rb            # one file
bin/rails test test/models/user_test.rb:42         # one test by line
bundle exec rubocop

# Docker — dev
docker compose -f docker-compose.dev.yml up --build
docker compose -f docker-compose.dev.yml --profile tools run --rm migrate
bin/dev-db-restore ~/Downloads/backup.sql   # restore a prod backup + seed a local sign-in account

# Docker — tests (image bind-mounts the repo; DB is dropped and reloaded each run)
docker compose -f docker-compose.test.build.yml build test    # first time / after Dockerfile.test changes
docker compose -f docker-compose.test.yml run --rm test
docker compose -f docker-compose.test.yml run --rm test bin/rails test test/models/user_test.rb

# Docker — lint
docker compose -f docker-compose.lint.build.yml build rubocop
docker compose -f docker-compose.lint.yml run --rm rubocop
```

CI (`.github/workflows/ci.yml`, on PRs to `main`/`staging`) runs `bundle exec rubocop` then `bin/rails test` — lint failures block merges, so run RuboCop before pushing.

Operational work is in `lib/tasks/*.rake` (`rails -T` to list). Most data-mutating tasks ship a dry-run twin (`membership:cleanup` / `membership:cleanup_preview`, `sponsored:mark` / `sponsored:preview`, etc.) — run the preview first.

## Architecture

### Authentication and authorization

Three sign-in paths, all landing in the same `User` record: Authentik OIDC (`/auth/authentik`), local database accounts (`LocalAuthConfig.enabled?`, for dev and emergencies), and RFID badge scan on the login page.

`ApplicationController` owns the whole auth surface: `current_user`, `true_user`, `can?`, `require_admin!`, `require_privilege!`. Controllers needing a session inherit `AuthenticatedController`.

Two rules that are easy to break:

- **Impersonation.** `current_user` is the impersonated user (so views render as them); `true_user` is the real admin. Every authorization check — `require_admin!`, `can?` — resolves against `true_user`, never `current_user`. Adding an authorization check that reads `current_user` creates a privilege-escalation hole.
- **Privileges are never granted directly to members.** Privileges bundle into `Role`s, roles attach to `TrainingTopic`s (`TrainingTopicRole`), and holding a topic (via `Training` for `trained_in`, or `TrainerCapability` for `can_train`) confers the topic's roles. `Privilege::CATALOG` is the authoritative key list. `Privilege#privilege_scope` is `global` (applies everywhere once conferred) or `topic` (applies only for the conferring topic) — hence `can?(key, topic:)`. `is_admin?` bypasses everything. In tests, use the `grant_privileges` helper in `test_helper.rb` to build that chain.

Roles are treated as portable configuration, not data: `rails roles:export` / `rails roles:import` key everything by name and privilege key rather than id.

### External integrations

Each integration follows the same shape: a service namespace under `app/services/`, jobs under `app/jobs/`, a rake task, and a "Sync now" button in the UI.

| Source | Services | Direction |
| --- | --- | --- |
| Authentik | `app/services/authentik/` | both ways |
| Google Sheets | `app/services/google_sheets/` | in (`sheet_entries`) |
| Slack | `app/services/slack/` | in (`slack_users`) |
| PayPal / Recharge | `app/services/paypal/`, `recharge/` | in (payments) |
| Ollama / AI | `app/services/ollama/` | out (application feedback, RAG) |

Authentik is the only bidirectional one and the only place with a push path. Pull: `Authentik::GroupSyncJob` reconciles the configured group into `users`, creating, updating, and deactivating. Push: model callbacks set `authentik_dirty` and enqueue `Authentik::UserSyncJob` when syncable fields change. **`Current.skip_authentik_sync` suppresses that push** — set it in any code that writes users while importing *from* Authentik, or the sync loops back on itself. API access uses a static `AUTHENTIK_API_TOKEN` bearer token; there is no OAuth refresh flow for API calls.

Stub all of these in tests. Swapping `Authentik::Client` needs `with_stubbed_authentik_client` from `test_helper.rb` (naive `const_set` breaks under Zeitwerk autoload).

### Encrypted fields

Personal data and third-party credentials are encrypted at rest — see `docs/encrypted-fields.md`. `SensitiveFields` (`app/models/concerns/sensitive_fields.rb`) provides `encrypts_sensitive_string`, `encrypts_sensitive_string_array`, `encrypts_sensitive_json`; readers/writers are overridden so callers see plaintext. Values carry markers (`enc:v1:`) so plaintext and ciphertext rows coexist.

The practical consequence: **you cannot `WHERE email LIKE '%foo%'` on an encrypted column.** Exact lookups go through the HMAC digest columns via `has_email_lookup` — `User.by_email`, `User.by_any_email` (includes `extra_emails`), `User.lookup_by_email`. Substring search over encrypted data is impossible; admin search UIs say "full email" for this reason.

### Membership state

A member's standing is one column, `users.membership_state`, and every rule about it lives on `User` — `MembershipState` (enum, `TRANSITIONS`, guard), `MembershipTransitions` (the verbs), `MembershipStateResolution` (deadlines), `MembershipStateProjection` (cached columns). `docs/membership-state-machine.md` is the spec.

Callers move members with transitions that name the event (`record_payment!`, `record_cancellation!`, `ban!`, `approve_application!`, …); illegal moves fail validation. **`active`, `membership_status`, and `dues_status` are projections rewritten on every save** — assigning them, or reaching for `update_columns` on them, accomplishes nothing and skips the guard, the `membership_state_entered_at` stamp, and the state-entry email. `Membership::ActiveStatus` survives only as a delegating adapter.

Several states expire on a clock rather than an event. `effective_membership_state` resolves elapsed deadlines on read; `Membership::TickJob` (daily, 4 AM) materializes them into the column. Grace periods and expiry windows come from `MembershipSetting`, not constants.

### Settings

`DefaultSetting` and `MembershipSetting` are singleton rows accessed via `.instance` with class-level convenience readers. `DefaultSetting` holds the Authentik group-naming scheme (`ctrlh:org:members:*` prefixes) that the group provisioner builds paths from. Editable copy lives in `TextFragment` records keyed by string, not in views.

### Background jobs

Sidekiq with sidekiq-cron; recurring jobs are declared inline in `config/initializers/sidekiq.rb`. **Never add `config.active_job.queue_name_prefix`** — it double-prefixes with sidekiq-cron's `active_job: true` and creates ghost queues. Queues are plain (`default`, `mailers`); cron entries use `active_job: true` and no explicit `queue:`.

## Conventions

- **Style:** single-quoted strings, 120-char lines, no `# frozen_string_literal: true` comments, all new RuboCop cops enabled. Pre-existing violations are grandfathered in `.rubocop_todo.yml`; new code must satisfy the Metrics limits in `.rubocop.yml` (method 25 lines, class 250 lines) — extracting a module is the usual fix when a class outgrows the limit.
- **Tests:** Minitest, `fixtures :all`, parallelized by processor count. Model tests in `test/models/`, service tests in `test/services/`, system tests (Capybara + Selenium) in `test/system/`.
- **Migrations:** reversible; add indexes for columns used in `WHERE`/`ORDER BY`/`JOIN`; new required columns on existing tables get `null: false` with a default. `jsonb` columns holding raw API payloads (`authentik_attributes`, `raw_attributes`) are GIN-indexed and queried through `with_attribute` scopes.
- **Views:** the UI has a specific design system documented in `.cursor/rules/ui.mdc` — read it before writing templates. Highlights: color only where it encodes meaning, at most one `btn-primary` per region, `-subtle` badges only, status dots over pills for the common case, `.table-compact` density, and the component classes in `refresh.css` rather than inline styles. Member-facing views layer onto the same structure as admin views with admin affordances removed and second-person voice.
- **Docs:** update `README.md` for setup/dependency/architecture changes and `docs/USER_GUIDE.md` for user-facing feature changes.

## Branch and release model

Work branches (`feature/*`, `fix/*`) target **`staging`**, never `main`. Production is promoted by a `staging` → `main` PR. No direct pushes to either protected branch. Hotfixes may branch from `main` and PR into it, followed by a re-sync PR back to `staging`. Squash-merge into `staging`; merge-commit the release PR.

The version lives in `VERSION` (plain text, semver) and is bumped in the release PR; merging to `main` tags the commit and builds `:latest` + `:vX.Y.Z` images to ghcr.io. Push to `staging` builds `:staging`.
