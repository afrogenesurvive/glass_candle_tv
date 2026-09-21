# Implementation Plan

**Project:** black_glass_candle — a finite, chronological, algorithm-free reading hub
**Status:** ready to build
**Upstream input:** [`agent_scaffold_plan.md`](./agent_scaffold_plan.md) (tutorial form; this document is the buildable form)

---

## 1. Goal

One place to read everything you have chosen to follow, with no recommendation engine,
no infinite scroll, and no engagement mechanics. A single chronological stream that
stops when you reach the bottom.

## 2. Non-goals

- Not a social product. No sharing, no commenting, no public instance.
- Not a replacement for a browser. Long-form reading still happens at the source.
- Not a mobile app. Mobile access is the existing FreshRSS web UI.

## 3. Architecture

```mermaid
graph TB
  subgraph Sources
    YT[YouTube channels]
    BB[Bear Blog]
    HN[Hacker News]
    LM[Lemmy]
    RD[Reddit]
    GH[GitHub repos/orgs]
    FM[Forums - CSS scraped]
    IG[Instagram - burner]
  end

  subgraph "rss-bridge (PHP)"
    RB[RSS-Bridge<br/>token-auth HTTP feed generator]
  end

  subgraph "freshrss (PHP)"
    FR[FreshRSS<br/>storage, filters, mute, API]
  end

  subgraph Clients
    MB[black_glass_candle.app<br/>macOS menu bar]
    WEB[Browser UI]
    DC[Discord webhook]
  end

  YT -->|native channel RSS| FR
  BB -->|native RSS| FR
  HN -->|hnrss.org| FR
  IG --> RB
  LM --> RB
  RD --> RB
  GH --> RB
  FM --> RB
  RB -->|feeds over internal network| FR
  FR --> MB
  FR --> WEB
  FR --> DC
```

**Why two applications.** RSS-Bridge turns "sites that have no feed" into feeds.
FreshRSS stores, deduplicates, categorises and schedules. They are different jobs with
different failure modes; keeping them separate means a broken bridge cannot corrupt the
feed database.

**Why a menu bar app.** The whole point is to remove the pull of an infinite feed. A
menu bar item that says "7 unread" and opens to exactly those 7 is the opposite of an
algorithm. It also surfaces the one number that matters without opening anything.

---

## 4. Workstreams

Each workstream is independently verifiable. Do not start the next until the acceptance
check passes.

### WS0 — Repository skeleton

| Item | Detail |
| --- | --- |
| Deliverables | `.gitignore`, `.env.example`, `env` (created by `install.sh`), `README.md`, `docs/`, `scripts/` |
| Key files | `.gitignore`, `.env.example` |
| Acceptance | `git status --short` never lists anything personal, and every secret-shaped path in the repo is ignored. The live data directory sits outside the checkout entirely, so the only remaining failure mode is a copy being made into the repo |
| Status | ✅ done — later amended: the data directory now lives outside the repo (`[0.0.1-2]` in [`CHANGELOG.md`](./CHANGELOG.md), *Where the data lives* in [`operations.md`](./operations.md)) |

> The `.gitignore` was written **before** `env` existed on purpose: a credentials file that
> appears in `git status` once is already too late. In that revision the live file sat
> under `private/` rather than at the repository root so a single rule covered it together
> with the feed database, logs, generated config and backups — and so `backup.sh`, which
> archives from inside that directory, picked it up without a special case.

### WS1 — Native service infrastructure

| Item | Detail |
| --- | --- |
| Deliverables | `scripts/install.sh`, `scripts/gen-configs.sh`, `scripts/services.sh`, launchd agents |
| Acceptance | `./scripts/install.sh` completes; all three launchd agents report `running`/`scheduled`; both endpoints answer on loopback; `./scripts/healthcheck.sh` reports no failures |

Requirements that the upstream scaffold omits and that this plan adds:

| # | Requirement | Why |
| --- | --- | --- |
| 1 | `CRON_MIN` wired to a launchd `StartCalendarInterval` | Without it the refresh job is never scheduled and feeds silently never update. The instance looks healthy while going stale. |
| 2 | `TZ` passed to PHP as `date.timezone` | A wrong TZ does not error; it silently shifts every date and breaks "today" filters. |
| 3 | Both listeners bound to `127.0.0.1` | Binding to all interfaces exposes the login page to the whole local network. |
| 4 | Logs written under `private/logs` | Without a location you control, diagnosing a crash means guessing. |
| 5 | A healthcheck on each service | A crashed process is otherwise indistinguishable from a quiet news day. |
| 6 | `private/` gitignored before it is populated | A credentials file that appears in `git status` once is already too late. |

### WS2 — FreshRSS configuration

| Item | Detail |
| --- | --- |
| Deliverables | Running instance with admin user, API enabled, API password set, categories created, Youlag installed |
| Acceptance | `curl` `POST /api/greader.php/accounts/ClientLogin` with `Email` + `Passwd` returns a line beginning `Auth=` |

| Status | ⬜ not started |

> ⚠️ **Account creation is skipped when the credentials are blank.** `install.sh` creates
> the admin account from `ADMIN_EMAIL` + `ADMIN_PASSWORD` in `private/env`. Leave either
> blank and it skips that step entirely: the services start normally, the API stays
> unusable, and the menu bar app reports "Password rejected". There is no volume to
> recreate — fill the values in and re-run `./scripts/install.sh`. Afterwards, change the
> account in the web UI; the env values are not re-applied on later runs.
>
> The **"Allow API access"** toggle is separate and manual. `install.sh` sets the API
> password (`cli/create-user.php --api-password`) but nothing can set `api_enabled` — the
> API returns 503 until the toggle is on, even with the password already stored.

Categories to create: `Tech`, `Reading`, `Forums`, `Video`, `Social`, `Media`
(see [`source_catalog.md`](./source_catalog.md) §4).

### WS3 — RSS-Bridge configuration

| Item | Detail |
| --- | --- |
| Deliverables | `private/apps/rss-bridge/config.ini.php` generated from `private/env`, token auth active, bridge allowlist applied |
| Acceptance | `http://127.0.0.1:3000/?action=display&bridge=CssSelectorBridge&format=Atom&token=$RSSBRIDGE_TOKEN` is rejected without a valid token; a wrong token returns `401`; `config/`, `cache/` and `bridges/` all return `404` |
| Status | 🟡 token auth and the allowlist both verified; credential plumbing corrected |

The explicit allowlist is a security control, not tidiness: RSS-Bridge ships 400+ bridges,
several of which make server-side outbound requests on your behalf.

Two properties of that allowlist are easy to get wrong, and **both fail silently** — the
file looks correct while doing nothing:

- `enabled_bridges[]` must sit **under `[system]`**. `BridgeFactory` reads
  `Configuration::getConfig('system', 'enabled_bridges')`, and a bare `enabled_bridges[]`
  line is parsed as belonging to whichever section header precedes it. Put it after
  `[cache]` and the list is ignored, leaving upstream's default of `*` — every bridge —
  in force.
- Only the keys a bridge declares in its own `CONFIGURATION` constant can be set from the
  config file, in a section named after the bridge class (`[GithubReleaseBridge] token`,
  `[InstagramBridge] session_id`). Several credentials in wide circulation are declared by
  no bridge in this release and therefore cannot be set at all: Reddit's client id and
  secret, and Instagram's `csrftoken`.

A useful diagnostic: a **400** means the bridge is not allowlisted, a **500** means it is
allowlisted and failed for some other reason.

### WS4 — Source onboarding

| Item | Detail |
| --- | --- |
| Deliverables | Every source in [`source_catalog.md`](./source_catalog.md) subscribed and receiving items |
| Acceptance | Each catalog row has a `verified` date; no feed shows a persistent error in FreshRSS |
| Blocked by | The feed list only you can supply — see [`inputs_required.md`](./inputs_required.md) §A6 |

### WS5 — Menu bar application

| Item | Detail |
| --- | --- |
| Deliverables | `black_glass_candle.app`, built by `scripts/build.sh` |
| Acceptance | Candle appears in the menu bar; unread count updates without restarting the app; clicking opens the popover; "Open FreshRSS" launches the web UI; app relaunches cleanly after `./scripts/services.sh stop` (shows a *stack down* state, not a crash) |
| Design | [`menubar_app.md`](./menubar_app.md) |

### WS6 — Taming the flow

| Item | Detail |
| --- | --- |
| Deliverables | Categories, mute/hide rules, filter rules, optional Discord webhook |
| Acceptance | The "All Articles" stream is something you actually want to read, and you reach the end of it |

This is the workstream that delivers the actual goal. WS1–WS5 are plumbing.

### WS7 — Operations

| Item | Detail |
| --- | --- |
| Deliverables | `scripts/backup.sh`, `scripts/restore.sh`, `scripts/upgrade.sh`, `scripts/healthcheck.sh` |
| Acceptance | A backup restored into a **clean** volume reproduces every subscription and category |
| Runbook | [`operations.md`](./operations.md) |

---

## 5. Sequencing

Status as of 2026-09-21. Kept here rather than inferred from the prose, because a plan
whose section markers all read as pending is indistinguishable from one that is half done.

| WS | Scope | Status |
| --- | --- | --- |
| WS0 | Repository skeleton | ✅ done |
| WS1 | Native service infrastructure | 🟡 both services running on loopback; the `refresh` agent was failing on every run (macOS privacy restriction on the repo's location) and was fixed by relocating the repository |
| WS2 | FreshRSS configuration | ⬜ not started — no admin account yet, so the API returns 400 |
| WS3 | RSS-Bridge configuration | 🟡 token auth verified; the allowlist was inert until `enabled_bridges[]` was moved under `[system]` |
| WS4 | Source onboarding | ⬜ 0 of 11 checklist steps; blocked on the feed list (input A6) |
| WS5 | Menu bar application | 🟡 builds and launches; acceptance not yet exercised, and it cannot pass until WS2 completes |
| WS6 | Taming the flow | ⬜ blocked on WS4 |
| WS7 | Operations | 🟡 scripts complete and corrected; no backup has been taken, so the restore acceptance is still unrunnable |

```mermaid
graph LR
  WS0["WS0<br/>skeleton ✅"] --> WS1["WS1<br/>native PHP"]
  WS1 --> WS2["WS2<br/>freshrss"]
  WS1 --> WS3["WS3<br/>rss-bridge"]
  WS2 --> WS4["WS4<br/>sources"]
  WS3 --> WS4
  WS2 --> WS5["WS5<br/>menubar app"]
  WS4 --> WS6["WS6<br/>taming"]
  WS5 --> WS6
  WS6 --> WS7["WS7<br/>ops"]
```

**Critical path: WS0 → WS1 → WS2 → WS5.** That produces a working menu bar reader
soonest. WS3/WS4 are additive and can be paused at any point without breaking reading.
WS7 should be done *before* WS4 if you value the subscription list — re-entering 40 feed
URLs by hand is genuinely punishing.

---

## 6. Risks

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Instagram bridge breaks after a Meta change | High | Low | `ENABLE_INSTAGRAM=0` flag; Instagram is one category, quarantined from the rest |
| Cookie expiry for Instagram | Certain | Low | Documented re-paste procedure; failure shows as an empty feed, not a crash |
| Forum CSS selectors rot when the forum restyles | Medium | Medium | One `FORUM_TARGETS` line per forum; breakage is isolated to that line |
| Reddit rate-limits the anonymous bridge | Medium | Medium | `RSSBRIDGE_USER_AGENT` escape hatch; Reddit OAuth credentials as fallback |
| `ADMIN_PASSWORD` left blank, so account creation is skipped | High (if unaware) | High | `install.sh` warns, `healthcheck.sh` reports it, and both are documented in `.env.example` and `docs/inputs_required.md`. Silent otherwise, which is why it is called out twice |
| Unbacked-up feed database lost | Low | High | WS7 moved earlier in the sequence; `backup.sh` before WS4 |
| Menu bar app pins a macOS version you later move off | Low | Low | Single `platforms:` line in `Package.swift` |

---

## 7. Decision log

| Decision | Rationale |
| --- | --- |
| Native PHP services over containers | On macOS, Docker keeps volumes inside one opaque VM disk image that Time Machine excludes, and its own docs advise against putting a database on a bind mount — so "data in a private folder" and "Docker on macOS" were mutually exclusive. PHP was already installed, so dropping containers cost no new dependency. |
| Document root set to FreshRSS's own `p/` directory | Makes the personal-data directory structurally unreachable over HTTP rather than merely unlinked. Verified with requests, not assumed. |
| A router script in front of RSS-Bridge | Its document root must also hold `config.ini.php` (the token) and a cache directory. The router permits only `/` and `/static/`. |
| Native Swift menu bar app over a SwiftBar plugin | Matches the existing `DS-mon` toolchain, shares its build script shape, and gives real SwiftUI for the popover. |
| Keychain over a custom encrypted key file | Removes an entire class of "where did the key file go" bugs. A hand-rolled AES-GCM key file has to manage its own permissions, backup and migration; the Keychain is strictly less to get wrong. |
| Programmatic icon over bundled PNG | No binary assets in git, no `.process()` resource declarations to keep in sync, and a template image adapts automatically to light/dark menu bars. |
| Explicit bridge allowlist over `enabled_bridges[] = *` | Least privilege on a service that fetches arbitrary URLs on request. |
