# black_glass_candle

A self-hosted reading hub. One finite, chronological stream from the sources you chose,
with no recommendation engine, no infinite scroll, and no engagement mechanics — plus a
macOS menu bar client so the only number you see is how much you have not read yet.

`FreshRSS` + `RSS-Bridge` running natively on PHP, and a Swift menu bar app on top.

---

## What this is

- **Everything you follow, in one place.** Blogs, YouTube channels, HN, Lemmy, Reddit,
  GitHub, forums, and (optionally) Instagram.
- **No algorithm.** The order is chronological and the list ends.
- **A menu bar client.** A candle that glows brighter as unread piles up, opening to
  exactly those articles. Not a browser tab.
- **Yours.** Runs on your machine, stores its own data in a folder you can see and back
  up, and sends nothing anywhere.

## Why not Docker

Docker on macOS keeps named volumes inside one opaque VM disk image. That means the feed
database is not a folder you can browse, copy in Finder, or back up — and Time Machine
excludes the disk image by default. Docker's own documentation also advises *against*
putting a database on a bind mount, so "keep my data in a private folder" and "use Docker
on macOS" pull in opposite directions.

This project runs PHP directly instead. The feed database is an ordinary directory, a
backup is a `tar`, and there is no VM to start, no image to pull, and no daemon that has
to be running before you can read.

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Homebrew | Any recent version |
| PHP 8.1+ | `brew install php`. **8.4 verified.** `pdo_sqlite`, `gmp`, `mbstring`, `intl`, `curl`, `dom`, `xml` and `simplexml` are all required or recommended. |
| Python 3 | Only for icon generation during the app build |
| Xcode or Command Line Tools | Only to build the menu bar app |

No web server package is needed: both apps are served by PHP's own built-in server.

## Quick start

```bash
git clone <this repo> && cd glass_candle_tv

# 1. Configure
cp .env.example private/env          # or let the installer do it
$EDITOR private/env                  # see docs/inputs_required.md

# 2. Install everything: clones both apps, generates config, loads launchd agents
./scripts/install.sh

# 3. Verify
./scripts/healthcheck.sh
```

Then open <http://127.0.0.1:8080>, complete setup, and **enable API access**
(*Administration → Authentication → "Allow API access"*) plus set an **API password**
(*Profile*). The menu bar app cannot work without both.

```bash
# 4. Build and configure the menu bar app
./scripts/build.sh
./scripts/seed_menubar_config.sh
open build/black_glass_candle.app    # first launch: right-click -> Open
```

## Where your data lives

**`private/` is gitignored in full.** The repository contains nothing personal — if you
can see it in a fresh clone, it was safe to publish.

```
private/
├── env                   deployment config: passwords and tokens (mode 600)
├── apps/FreshRSS/
│   └── data/             ← subscriptions, categories, feeds, read state, database
├── apps/rss-bridge/      cloned code + config.ini.php (the shared token)
├── etc/                  generated request router
├── logs/                 service and refresh logs
├── run/                  pid files
└── backups/              snapshots from scripts/backup.sh
```

The web server's document root for FreshRSS is its own `p/` directory — which is exactly
what FreshRSS's documentation asks for:

> For better security, expose only the `./p/` folder to the Web. Be aware that the
> `./data/` folder contains all personal data, so it is a bad idea to expose it.

Because `data/` is a **sibling** of `p/`, it is not in the served tree at all. There is no
URL that resolves to it, so this is structural rather than a rule that could be got wrong.
`healthcheck.sh` asserts it.

## Documentation

| Document | Contents |
| --- | --- |
| [`docs/implementation_plan.md`](docs/implementation_plan.md) | Workstreams, acceptance criteria, sequencing, risks |
| [`docs/inputs_required.md`](docs/inputs_required.md) | **Every value you must provide**, how to obtain it, and its risk |
| [`docs/menubar_app.md`](docs/menubar_app.md) | Menu bar app architecture and the FreshRSS API contract |
| [`docs/source_catalog.md`](docs/source_catalog.md) | Per-source setup, and how each one breaks |
| [`docs/operations.md`](docs/operations.md) | Backup, restore, upgrade, rotate, diagnose |
| [`docs/CHANGELOG.md`](docs/CHANGELOG.md) | Change history |
| [`docs/agent_scaffold_plan.md`](docs/agent_scaffold_plan.md) | The original upstream tutorial this project started from (historical) |

## Scripts

| Command | Does |
| --- | --- |
| `./scripts/install.sh` | Full native install. Idempotent. |
| `./scripts/gen-configs.sh` | Regenerate the router and RSS-Bridge config from `private/env` |
| `./scripts/services.sh` | `install` / `start` / `stop` / `restart` / `status` / `uninstall` the launchd agents |
| `./scripts/refresh-feeds.sh` | Refresh every feed. Run by launchd on the `CRON_MIN` schedule. |
| `./scripts/backup.sh` | Snapshot the data directory and config. `--list` to see them. |
| `./scripts/restore.sh` | Restore a snapshot. The current data is moved aside, not deleted. |
| `./scripts/upgrade.sh` | `git pull` both apps, restart, verify. `--dry-run` to preview. |
| `./scripts/install-youlag.sh` | Install or update the Youlag extension |
| `./scripts/seed_menubar_config.sh` | Push `private/env` into the app's Keychain + prefs. `--show` / `--clear` |
| `./scripts/build.sh` | Build and package `black_glass_candle.app` |

## Security notes

- **`private/` holds everything personal and is gitignored**, by a single root-level rule.
- **Both services bind to `127.0.0.1` only.** Your feed reader and its login page are not
  reachable from other machines on the network.
- **RSS-Bridge requires a token** on every feed URL. This is verified, not assumed: a bad
  token returns `401`, and `healthcheck.sh` fails if it ever returns `200`.
- **The RSS-Bridge document root is filtered by a router** that permits only `/` and
  `/static/`. `config.ini.php` (the token), `cache/`, `bridges/` and `composer.json` all
  return 404.
- **Instagram ships disabled** (`ENABLE_INSTAGRAM=0`). It is the only source needing full
  account credentials, and it is isolated so a breakage there cannot affect any other feed.
  Use a burner account, never your personal one.
- The menu bar app is **unsigned**; first launch needs right-click → Open.

## Design notes

Decisions that are load-bearing and easy to "fix" into breakage:

- **`CRON_MIN` is required.** Without it the refresh job is never scheduled and feeds
  silently never update. The instance still looks perfectly healthy.
- **RSS-Bridge reads `config.ini.php` from its repository root**, not from `config/`.
  That path is the Docker image's convention. Put it in the wrong place and RSS-Bridge
  does not complain — it runs with defaults and token authentication is silently off.
- **An unknown bridge name is ignored silently.** Verify names against the clone's
  `bridges/` directory; several names in common circulation do not exist.
- **The bridge probe must use a bridge that exists.** An unknown name returns 404 *before*
  the token check runs, which turns a security test into one that can never fail.
- **`php -S` worker count** comes from `PHP_CLI_SERVER_WORKERS`. The default of 1 means a
  single slow request blocks the whole interface.
- **`-Onone` in `build.sh` is deliberate.** Swift 6.3.3 with `-O` silently drops string
  literals, which shows up as blank labels rather than a build error.

## Licence

MIT — see [`LICENSE`](LICENSE).

Third-party components keep their own licences: FreshRSS (AGPL-3.0), RSS-Bridge
(Unlicense), and the Youlag extension (GPL-3.0, downloaded at install time rather than
vendored).
