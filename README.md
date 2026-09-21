# black_glass_candle

A self-hosted reading hub. One finite, chronological stream from the sources you chose,
with no recommendation engine, no infinite scroll, and no engagement mechanics — plus a
macOS menu bar client so the only number you see is how much you have not read yet.

`FreshRSS` + `RSS-Bridge` in Docker, and a native Swift menu bar app on top.

---

## What this is

- **Everything you follow, in one place.** Blogs, YouTube channels, HN, Lemmy, Reddit,
  GitHub, forums, and (optionally) Instagram.
- **No algorithm.** The order is chronological and the list ends.
- **A menu bar client.** A candle that glows brighter as unread piles up, opening to
  exactly those articles. Not a browser tab.
- **Yours.** Runs on your machine, stores its own data, sends nothing anywhere.

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Docker Desktop / OrbStack / colima | **Not currently installed on this Mac** — install one before WS1. |
| macOS 15+ | For the menu bar app. Apple Silicon or Intel. |
| Swift 6 toolchain | Only needed to build the app; Xcode or Command Line Tools. |
| Python 3 | Only for icon generation during the app build. |

## Quick start

```bash
# 1. Configure
cp .env.example .env
$EDITOR .env                     # see docs/inputs_required.md for every value

# 2. Generate the RSS-Bridge config from .env
./scripts/gen-rssbridge-config.sh

# 3. Start the stack
docker compose up -d
docker compose ps                # both should reach (healthy)

# 4. Verify
./scripts/healthcheck.sh
```

Then open <http://127.0.0.1:8080>, log in, and **enable API access**
(*Administration → Authentication → "Allow API access"*) plus set an **API password**
(*Profile*). The menu bar app cannot work without both.

```bash
# 5. Build and configure the menu bar app
./scripts/build.sh
./scripts/seed_menubar_config.sh
open build/black_glass_candle.app    # first launch: right-click -> Open
```

## Documentation

| Document | Contents |
| --- | --- |
| [`docs/implementation_plan.md`](docs/implementation_plan.md) | The build plan: workstreams, acceptance criteria, sequencing, risks |
| [`docs/inputs_required.md`](docs/inputs_required.md) | **Every value you must provide**, how to obtain it, and its risk |
| [`docs/menubar_app.md`](docs/menubar_app.md) | Menu bar app architecture and the FreshRSS API contract |
| [`docs/source_catalog.md`](docs/source_catalog.md) | Per-source setup, and how each one breaks |
| [`docs/operations.md`](docs/operations.md) | Backup, restore, upgrade, rotate, diagnose |
| [`docs/agent_scaffold_plan.md`](docs/agent_scaffold_plan.md) | The original upstream tutorial this project is built from |

## Layout

```
.
├── docker-compose.yml            FreshRSS + RSS-Bridge
├── docker-compose.db.yml         Optional PostgreSQL overlay
├── .env.example                  Template — copy to .env and fill in
├── Package.swift                 Menu bar app (SwiftPM, no Xcode project)
├── Sources/BlackGlassCandle/     Menu bar app source
├── rss-bridge-config/            RSS-Bridge config (generated from .env)
├── freshrss-extensions/          Third-party extensions (Youlag)
├── docs/                         Documentation
└── scripts/
    ├── lib-common.sh             Shared shell helpers
    ├── build.sh                  Build + package the .app
    ├── gen_icon.py               Generate the app icon (stdlib only)
    ├── gen-rssbridge-config.sh   .env -> config.ini.php
    ├── install-youlag.sh         Install/update the Youlag extension
    ├── seed_menubar_config.sh    .env -> Keychain + UserDefaults
    ├── backup.sh                 Snapshot the feed database
    ├── restore.sh                Restore from a snapshot
    ├── upgrade.sh                Safe image upgrade with pre-backup
    └── healthcheck.sh            Whole-stack status
```

## Scripts

| Command | Does |
| --- | --- |
| `./scripts/healthcheck.sh` | Status of every component; exits non-zero on failure |
| `./scripts/backup.sh` | Snapshot the feed database. **Run this early.** |
| `./scripts/restore.sh` | Restore from a snapshot (destructive, prompts) |
| `./scripts/upgrade.sh` | Back up, pull, recreate, verify. `--dry-run` to preview |
| `./scripts/gen-rssbridge-config.sh` | Regenerate the bridge config from `.env` |
| `./scripts/install-youlag.sh` | Install or update Youlag |
| `./scripts/seed_menubar_config.sh` | Push `.env` into the app's Keychain + prefs. `--show` / `--clear` |
| `./scripts/build.sh` | Build and package `black_glass_candle.app` |

## Security notes

- **`.env` is gitignored, and was gitignored before it existed.** It holds the FreshRSS
  API password, the RSS-Bridge token, and — if you enable Instagram — live session
  cookies for an account. Never commit it, never paste it into an issue or a chat.
- **Everything binds to `127.0.0.1` by default.** Your feed reader and its login page are
  not reachable from the café Wi-Fi network.
- **Instagram is off by default** (`ENABLE_INSTAGRAM=0`). It is the only source that needs
  full account credentials, and it is quarantined so that when it breaks it takes nothing
  else with it.
- **Use a burner Instagram account.** Never your personal one.
- The app is **unsigned**. First launch needs right-click → Open.

## Design notes

A few decisions that are load-bearing and easy to "fix" into breakage:

- **`CRON_MIN` is required.** Without it FreshRSS disables its cron daemon entirely and
  feeds never refresh. The instance still looks healthy.
- **`INTERNAL_HOST_ALLOWLIST` must include `rss-bridge:80`.** FreshRSS blocks requests to
  internal hosts by default, so bridged feeds silently fail to fetch.
- **`FRESHRSS_INSTALL` / `FRESHRSS_USER` are first-run only.** Editing them later does
  nothing; changing them requires `docker compose down -v`, which deletes every
  subscription.
- **The popover window overrides `canBecomeKey`.** A default borderless `NSWindow` cannot
  become key, and text fields inside a non-key window silently ignore keystrokes.
- **The menu bar glyph is drawn, not bundled.** No binary assets in git, and it stays
  crisp at any scale.
- **`-Onone` in `build.sh` is deliberate.** Swift 6.3.3 with `-O` silently drops string
  literals, which shows up as blank labels rather than a build error.

## Licence

MIT — see [`LICENSE`](LICENSE).

Third-party components keep their own licences: FreshRSS (AGPL-3.0), RSS-Bridge
(Unlicense), and the Youlag extension (GPL-3.0, downloaded at install time rather than
vendored).
