# Development, staging, and releases

How code gets from your laptop to production: branches, pull requests, images, and version
numbers. See also [deployment-rules.mdc](../.cursor/rules/deployment-rules.mdc) for the
same policy in rule form.

## TL;DR

```bash
# 1. Work
git checkout -b fix/thing origin/staging
# ... commit ...
git push -u origin fix/thing
gh pr create --base staging --fill
gh pr merge --auto --squash --delete-branch   # merges itself when CI is green

# 2. That merge publishes :staging automatically. Nothing else to do.

# 3. Promote when staging looks good (merge commit, not squash)
gh pr create --base main --head staging --title "Promote staging"

# 4. Release. This is the only thing that versions anything.
gh workflow run release.yml -f bump=minor
```

Six things worth knowing up front:

- **The newest `v*` git tag is the version.** There is no `VERSION` file. Never hand-write a
  version number into a commit.
- **Merging to `main` publishes nothing.** It only makes code eligible to release.
- **Releasing is a manual button**, not a branch and not a merge.
- **Local development never builds a published image.** It bind-mounts your working copy.
- **`ci` is the only required status check.** Everything else is advisory.
- **Work branches target `staging`**, never `main`.

## Branches

| Branch | Purpose | Merge style |
|---|---|---|
| `main` | What production is released from | Merge commit |
| `staging` | Integration; what the staging server runs | Squash |
| `feature/*`, `fix/*` | Your work. Short-lived, deleted after merge | — |
| `hotfix/*` | Emergency fix straight into `main` | Squash |

No direct pushes to `main` or `staging` — everything arrives by pull request.

## Where images come from

| Event | Image tags published | Consumed by |
|---|---|---|
| PR merged into `staging` | `:staging`, `:staging-<sha>` | Staging server |
| PR merged into `main` | *nothing* | — |
| `release.yml` run manually | `:latest`, `:X.Y.Z`, `:MAJOR` | Production server |
| `rebuild-tag.yml` run manually | `:X.Y.Z` only | — |

Images go to `ghcr.io/pdxhackerspace/member-zone`.

**Nothing in this repository deploys.** CI publishes images; the servers pull them. The
deploy mechanism itself (whatever pulls `:staging` and `:latest`) lives outside this repo,
which is why `:staging` and `:latest` are mutable tags — they are the interface.

---

## Local development

A dev instance runs your working copy directly. It does not build or push a published
image, is not versioned, and never participates in a release.

### Running it

The normal path is Docker, which brings up Postgres, Redis, Rails, and Sidekiq together:

```bash
docker compose -f docker-compose.dev.yml up --build
```

The app is at http://localhost:3000. Your checkout is bind-mounted at `/rails`, so edits
show up without rebuilding — the `--build` is only needed when the `Dockerfile` or
dependencies change.

If you have Postgres and Redis running natively, `bin/dev` is lighter. It runs the Rails
server and `yarn watch:css` under foreman:

```bash
bin/dev
```

Configure `.env` first — see `.env.development.example`. Compose injects `DB_HOST`,
`DATABASE_URL`, and `REDIS_URL` itself, so you don't need those, but `AUTHENTIK_API_TOKEN`
must be set (it may be empty) because it is required at boot.

### Migrations

```bash
docker compose -f docker-compose.dev.yml --profile tools run --rm migrate
```

### Real data to work against

```bash
bin/dev-db-restore ~/Downloads/backup-mm.sql
```

This drops and recreates `member_zone_development`, loads the backup, applies migrations the
backup predates, and creates a local sign-in account from `LOCAL_AUTH_EMAIL` /
`LOCAL_AUTH_PASSWORD`. That last step matters: production authenticates through Authentik,
so its backups contain no `local_accounts` rows and a freshly restored copy has no way to
sign in. Use this rather than `pg_restore` directly — see the README for why the archive
format requires it.

Set `LOCAL_AUTH_ENABLED=true` and sign in through the **Sign in locally** form at `/login`.

### Tests and lint

Run these before pushing; CI runs the same two commands and lint failures block merges.

```bash
docker compose -f docker-compose.test.yml run --rm test
docker compose -f docker-compose.test.yml run --rm test bin/rails test test/models/user_test.rb
docker compose -f docker-compose.lint.yml run --rm rubocop
```

Build or refresh those images the first time on a machine, or after `Dockerfile.test` /
`Dockerfile.rubocop` changes:

```bash
docker compose -f docker-compose.test.build.yml build test
docker compose -f docker-compose.lint.build.yml build rubocop
```

### What version a dev instance reports

The footer shows `dev`.

`APP_VERSION` is only baked into published images, and nothing sets it in the dev stack.
`AppVersion` then tries `git describe`, which fails inside the container because `git` is
installed in the Docker build stage but not in the runtime image — so it falls through to
`dev`, which is the honest answer for a working copy.

Running natively with `bin/dev` does find `git` and reports a `git describe` string like
`0.50.1-109-gabc1234`, with `-dirty` appended when you have uncommitted changes.

Set `APP_VERSION` in `.env` if you want a dev instance to claim something specific.

---

## Pull requests

Branch from `staging`, name it `feature/*` or `fix/*`, and target `staging`:

```bash
git checkout -b fix/thing origin/staging
git push -u origin fix/thing
gh pr create --base staging --fill
```

### What CI runs

One job, named `ci`, on every PR into `main` or `staging`: RuboCop, `yarn test:js`,
`db:test:prepare`, then `bin/rails test`. There are no exemptions — every commit that can
reach production is fully tested.

### What must pass

`ci` is the only **required** check. The other checks that appear on a PR —
`allowed-main-source`, Bugbot — are advisory: they will not block a merge, but a red one
usually means something real, so read it before overriding.

### Approvals

Currently **zero approvals are required**, so you can merge your own PR once `ci` is green.
This is the one setting that changes when a project has more than one developer — raise the
review count and nothing else about the process moves. Turn on auto-merge and walk away:

```bash
gh pr merge --auto --squash --delete-branch
```

Squash-merge into `staging`. Keep `staging` deployable — use a draft PR for work in
progress rather than merging something half-finished.

---

## Staging

Merging a PR into `staging` builds and publishes `:staging` and `:staging-<short-sha>`. The
staging server pulls `:staging`.

Staging reports a version like `0.50.1+109.abc1234.staging`, meaning "109 commits past
release 0.50.1, built from `abc1234`". That anchors to the newest release tag in the
repository rather than to `git describe`, because `describe` walks ancestry and `staging`
has diverged from `main` — describing would anchor to a much older tag and make staging
look *older* than production.

To rebuild staging without merging anything, run the `Staging - Build and Push Image`
workflow manually from the Actions tab.

## Promoting to `main`

```bash
gh pr create --base main --head staging --title "Promote staging"
```

Use a **merge commit** so history is preserved. Only `staging` and `hotfix/*` may merge into
`main`; `allowed-main-source` flags anything else.

This publishes no image and changes no version. It only makes the code eligible to be
released.

## Releasing

```bash
gh workflow run release.yml -f bump=minor                    # patch | minor | major
gh workflow run release.yml -f bump=minor -f dry_run=true    # preview, changes nothing
gh workflow run release.yml -f bump=patch -f sha=abc1234     # release an older commit
```

`release.yml` reads the newest `v*` tag, computes the next semver, builds the image with
that version baked in, publishes `:latest` / `:X.Y.Z` / `:MAJOR`, then tags the commit and
opens a GitHub Release with generated notes. The production server pulls `:latest`.

It refuses to run if the commit is not an ancestor of `main`, or if the computed tag already
exists. It tags **after** the image is published, so a failed build leaves no tag behind and
you can simply run it again.

`dry_run=true` prints the plan — previous tag, next version, target commit — to the run
summary and stops.

To rebuild the image for a tag that already exists (a corrupted push, a base-image CVE),
use the `Rebuild image for an existing tag` workflow. It republishes `:X.Y.Z` only, never
`:latest`, and never creates or moves a tag.

## Versioning

Semantic versioning: patch for fixes, minor for features, major for breaking changes.

**The newest `v*` git tag is the canonical version.** There is no `VERSION` file, nothing in
a commit records a version number, and the release workflow is the only thing that assigns
one.

`APP_VERSION` is baked in at build time:

| Build | `APP_VERSION` |
|---|---|
| Production release | `0.51.0+abc1234` |
| Staging | `0.50.1+109.abc1234.staging` |
| Rebuilt tag | `0.50.1+abc1234` |
| Local Docker dev | `dev` |
| Local native (`bin/dev`) | `0.50.1-109-gabc1234` |

Everything after `+` is [semver build metadata](https://semver.org/#spec-item-10), so the
leading `MAJOR.MINOR.PATCH` is what humans read and compare while the exact commit stays
recoverable. Read it through `AppVersion` (`config/initializers/version.rb`):

| | |
|---|---|
| `AppVersion.semver` | `0.51.0` — show this to people |
| `AppVersion.commit` | `abc1234` — build metadata, or `nil` |
| `AppVersion.current` | `0.51.0+abc1234` — the whole string |

The footer shows `.semver` with `.current` in a `title` attribute for hover precision.

### Why there is no VERSION file

There used to be, and it drifted: `main` sat at `0.50.1` while `staging` sat at `0.36.18`,
because release bumps landed on `main` and never flowed back. Staging images were mislabelled
for fourteen minor versions, and every Dependabot security PR failed the guard that kept the
file out of `staging`. A version is a property of the repository, not of a branch, so it
belongs in a tag. Please don't reintroduce one.

## Hotfixes

When production is broken and waiting for `staging` isn't acceptable:

```bash
git checkout -b hotfix/brief-description origin/main
gh pr create --base main --fill        # PR into main directly
gh workflow run release.yml -f bump=patch
gh pr create --base staging --head main --title "Re-sync main into staging"
```

That last step matters — without it `staging` drifts from `main` and the next promotion PR
carries surprises.

## Rolling back

Releases are immutable tags, so a bad release does not need a revert to get out of
production. Point the server at the previous version tag (`:0.50.1` rather than `:latest`),
or run `Rebuild image for an existing tag` and redeploy. Then fix forward through the normal
path.

## Gotchas

**Dependabot security PRs target `main`.** Version-update PRs honour `target-branch: staging`
in `.github/dependabot.yml`, but *security* updates ignore it and open against the default
branch. Retarget them to `staging` and rebase onto it — a branch cut from `main` carries
main's commits, which is confusing at best in a staging PR.

**Workflow changes only take effect once they reach `main`.** A PR that edits `release.yml`
does not change how the next release behaves until it has been promoted.

**Never commit secrets.** Use Actions Secrets for CI and server-side environment variables at
runtime. Treat a secret in a diff as a hard blocker.
