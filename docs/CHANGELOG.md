# Changelog

Notable changes to **black_glass_candle**.

Version format is `<branch>-<n>`, where `n` is the entry number on that branch
(`0.0.1-1` is the first). This repository has no separate internal changelog — these
entries are public and deliberately exclude credential, path and release mechanics.

---

## [0.0.1-3] — 2026-09-21

The last of the container-era residue is gone, along with four places where the app
told you something untrue about how the stack works.

### Fixed

- **The menu bar app described a Docker volume that does not exist.** Its About pane said
  that backing up "means snapshotting a Docker volume, which this app cannot do safely" —
  there is no volume, and a backup is a plain archive of a folder. The text now describes
  what `scripts/backup.sh` actually does.
- **Three comments in the app blamed a stopped Docker daemon** for what is now a stopped
  launchd agent. That confusion matters: it points a reader at a service they are not
  running instead of the one that has actually stopped.
- **Two documents used "volume" where they meant the `data/` directory**, and the Youlag
  install path was written as `freshrss-extensions/` — a container-era path that does not
  exist. It now names the FreshRSS clone's own `extensions/` directory.
- **The environment file's header still described the container layout.** It advised
  running `docker compose down -v` to change the admin account — a command that would have
  deleted every subscription had anyone followed it. The header documents the native
  layout instead, and two settings the scripts read but the file never carried
  (`PHP_CLI_SERVER_WORKERS`, `RSSBRIDGE_CACHE_DURATION`) are now present with their real
  defaults.
- **`scripts/backup.sh` could never succeed.** Its archive paths named `FreshRSS/data`,
  but the applications live under `private/apps/`, so `tar` aborted on the first target —
  and because its error output was discarded, the failure presented as a successful 4 KB
  backup. Paths are now derived from the real locations, `tar`'s own message is reported,
  and a partial archive is deleted rather than left for a restore to pick up. The first
  backup has been taken.
- **Four scripts printed a broken `--help`.** `build.sh` ended its help with a line of shell
  code, and `restore.sh`, `services.sh` and `verify-feed.sh` cut off mid-sentence. The text is
  produced by a hardcoded line range, so a header that grows or shrinks silently changes what
  is printed; each range was measured against its header and corrected.
- **The healthcheck's API check could never pass.** It probed the bare API endpoint, which
  returns `400` before FreshRSS ever consults the `api_enabled` flag — so the warning
  persisted whether the API was on, off, or unreachable, and could not be cleared by any
  amount of correct setup. It now probes a real route and distinguishes `401` (enabled)
  from `503` (disabled).

### Changed

- **`.gitignore` no longer carries rules for directories that no longer exist.** `private/`
  remains the single backstop covering every path that holds personal state, and every
  rule matching a live configuration file is unchanged.
- The environment template no longer ships container hostnames as default values, and the
  changelog's own format example names the branch the entries actually use.

### Notes

- No behaviour changed in the services themselves. Backup, restore and upgrade are
  unaffected, and the first backup has been verified to contain the database, the
  configuration and the bridge token.
- `api_enabled` can be set without the web UI: `php cli/reconfigure.php --api-enabled`.
  The running workers keep the old configuration until the service is restarted, so follow
  it with `./scripts/services.sh restart freshrss`.
- Historical references to Docker are kept in this changelog and in
  `agent_scaffold_plan.md`: they record what the project started from.

---

## [0.0.1-2] — 2026-09-21

Personal state moved out of the checkout, so the repository can live anywhere — and the
scheduled refresh finally works from a machine that protects `~/Documents`.

### Changed

- **The data directory is no longer inside the repository.** It lives in
  `~/Library/Application Support/glass_candle_tv/private`. The checkout now contains
  nothing personal at all, and `private/` stays gitignored as a backstop so a stray copy
  can never be committed.
- **The refresh job runs a staged copy of its script.** macOS denies a background job
  access to `~/Documents`, `~/Desktop` and `~/Downloads`; the read fails and the job exits
  126, which looks exactly like "nothing new today". `./scripts/services.sh install`
  deploys the two files the job needs beside the data, and the healthcheck reports a stale
  copy rather than letting the schedule quietly run old code.
- **A refresh that finds nothing new is no longer logged as a failure.** FreshRSS's CLI
  exits non-zero when it updates zero feeds — its success test is "did anything change",
  not "did anything go wrong" — so a quiet run now records `exit 0 — ok`.
- **The service status check no longer warns about RSS-Bridge's `401`.** The root page
  requires the token, so an unauthenticated probe is supposed to be rejected.

### Why

The previous layout kept everything in one folder, which is easier to reason about but
collides with macOS privacy protection: with the checkout under `~/Documents`, the
refresh job could not read its own script. Moving the whole project out of `~/Documents`
fixed it at the cost of putting the code somewhere you did not want it. Splitting the data
out satisfies the same constraint while leaving the checkout wherever you prefer — and it
is what the split should have been from the start, since only what a background job must
*read* is affected.

---

## [0.0.1-1] — 2026-09-21

Runs natively on PHP. The container stack is gone, and everything personal now lives in a
single gitignored folder.

### Changed

- **Replaced Docker with a native PHP install.** Both applications run under PHP's own
  server, one process each, supervised by launchd. No web server package is required, and
  there is no VM to start before you can read.
- **All personal state moved into `private/`**, which is gitignored by one rule. The
  repository contains nothing personal. This covers the configuration file, the feed
  database, the cloned applications, generated configuration, logs and backups.
- **The feed database is now an ordinary folder** you can browse, copy in Finder and back
  up with `tar`. It was previously inside a container volume.
- **Backup and restore are simpler** as a result: an archive is a plain tarball, and a
  restore moves the current data aside rather than deleting it.
- **Upgrading is a `git pull`** of the two applications rather than pulling images. Your
  data lives in a separate directory and is untouched.

### Why

On macOS, Docker keeps named volumes inside one opaque VM disk image which Time Machine
excludes by default, and Docker's own documentation advises against putting a database on
a bind mount. Keeping personal data in a folder you control and using Docker on macOS pull
in opposite directions, so one of them had to go.

### Security

- Both services listen on loopback only.
- The FreshRSS document root is its own `p/` directory, so the personal-data directory is
  **not in the served tree at all** — there is no URL that resolves to it. This is now
  asserted by the healthcheck rather than assumed.
- A router in front of RSS-Bridge permits only `/` and `/static/`; its configuration file,
  cache and application tree all return 404.
- Feed URLs require a token, and the healthcheck now fails if a wrong token is ever
  accepted.

### Fixed

- **RSS-Bridge token authentication was silently disabled.** The configuration file was
  being written to the location the container image expects; a native install reads it from
  the application's own root. With it in the wrong place the service started normally with
  authentication off, and a wrong token was accepted.
- **Several bridge names in the default list do not exist.** Unknown names are ignored
  without warning, so the list was failing quietly. It now contains only verified names.
  Notably, Hacker News no longer has a usable bridge — use the native feed instead.
- The healthcheck's authentication test previously probed a bridge that does not exist,
  which returns 404 before the token check runs. It was therefore incapable of failing.
- The healthcheck reported a working service as unreachable, due to a status-code helper
  that concatenated two failure values.

### Removed

- `docker-compose.yml` and the optional database overlay.
- The Docker-oriented backup, restore, upgrade and healthcheck scripts, all rewritten.

---

## [main-1] — 2026-09-21

Initial scaffold. Turns the upstream tutorial in `docs/agent_scaffold_plan.md` into a
buildable, documented project.

### Added

- **Container stack** — `docker-compose.yml` running FreshRSS and RSS-Bridge, plus an
  optional PostgreSQL overlay.
  - Feeds refresh on a schedule (`CRON_MIN`); without it FreshRSS disables its cron
    daemon entirely and feeds silently never update.
  - Both services expose healthchecks, and container logs are size-capped.
  - FreshRSS is permitted to reach RSS-Bridge over the internal Docker network, which it
    blocks by default.
- **Menu bar client** — a native Swift/SwiftPM macOS app, `black_glass_candle.app`:
  - Candle glyph and a flame indicator whose colour and height both track unread
    pressure, so the cue does not rely on colour alone.
  - Popover with unread counts by category, a list of unread articles, and one-click
    mark-all-read.
  - Optional full web interface embedded in the panel for subscribing to new feeds.
  - Distinct states for "stack unreachable", "password rejected" and "API access
    disabled", each paired with its own fix.
  - The API password is stored in the macOS Keychain, not in a preferences file.
- **Operations scripts** — `healthcheck`, `backup`, `restore`, `upgrade`,
  `gen-rssbridge-config`, `install-youlag`, `seed_menubar_config` and `build`.
- **Configuration template** — `.env.example`, with every value annotated.
- **Documentation** — implementation plan, input requirements, menu bar architecture,
  source catalog and an operations runbook.

### Security

- `.env` and its variants are ignored by git; secrets files were ignored before any were
  created, rather than after.
- Every published port binds to loopback by default, so the reader and its login page are
  not reachable from other machines on the network.
- The Instagram source ships **disabled**. It is the only source requiring full account
  credentials, and it is isolated so that a breakage there cannot affect any other feed.
- The app bundle allows cleartext HTTP to local networks only, not to arbitrary hosts.

### Notes

- Adding a source is a maintenance commitment. The project deliberately favours a small
  number of feeds that get read over a large number that get skimmed.
- Instagram, Reddit and CSS-scraped forums are the fragile sources. All three are
  contained: when one breaks, the failure shows as a single empty category.
