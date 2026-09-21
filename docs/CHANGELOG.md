# Changelog

Notable changes to **black_glass_candle**.

Version format is `<branch>-<n>`, where `n` is the entry number on that branch
(`main-1` is the first). This repository has no separate internal changelog — these
entries are public and deliberately exclude credential, path and release mechanics.

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
