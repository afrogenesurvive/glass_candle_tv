# Changelog

Notable changes to **black_glass_candle**.

Version format is `<branch>-<n>`, where `n` is the entry number on that branch
(`main-1` is the first). This repository has no separate internal changelog — these
entries are public and deliberately exclude credential, path and release mechanics.

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
