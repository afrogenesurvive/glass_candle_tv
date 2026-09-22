# Handover — what is left undone

Written 2026-09-21, at the end of a long working session; revised the same evening after
the container-era residue was removed and API access was turned on. The stack runs, the
API answers, and a first backup exists. It has **nothing to read yet**, and the only thing
between here and that is the admin login — one interactive command.

**§3 is the authoritative list of what is left.** It is a checklist, not prose.

---

## 1. Where things stand

**Repository:** `~/Documents/GitHub/glass_candle_tv`
(back where it belongs — `git`, the editor and these scripts all run from a terminal,
which has the file access that launchd does not)

**Data:** `~/Library/Application Support/glass_candle_tv/private` — deliberately outside
the repo, and required rather than preferred. macOS TCC stops a launchd job reading
anything under `~/Documents`, which is what was killing the feed-refresh job; the whole
repo was moved out of `~/Documents` to work around that. Now only the data lives outside,
`services.sh install` stages the agent scripts beside it, and the repo path is free
again. See *Where the data lives* in `docs/operations.md`.

**Working:**

| Thing | State |
| --- | --- |
| `freshrss` on `127.0.0.1:8080` | running, launchd `KeepAlive` |
| `rssbridge` on `127.0.0.1:3000` | running, token auth enforced, allowlist enforced |
| `refresh` agent | scheduled at `:13` and `:43`; now actually executes |
| `healthcheck.sh` | 0 failures, **1 warning** — the account password, and nothing else |
| FreshRSS API | **enabled** — `/reader/api/0/token` answers `401` (it returned `503`) |
| FreshRSS installed | `data/config.php` exists; account `admin` exists |
| first backup | taken 2026-09-21 — `~/Backups/black_glass_candle/` |
| `php` formula | pinned |
| duplicate checkout | **deleted** 2026-09-21 — see §5 |

---

## 2. Blocked on you, in order

### 2.1 Set the admin login — do this first

```bash
cd ~/Documents/GitHub/glass_candle_tv
./scripts/set-admin-credentials.sh
```

Prompts for the email and a password (hidden, confirmed), writes them to `private/env`,
and rotates the existing account.

**Why this is urgent and not just tidiness:** the account's password was rotated to a
random value that was deliberately discarded, so **no password currently works**. That
was done on purpose — see §4.

### 2.2 Then, in the browser at `http://127.0.0.1:8080`

1. Log in.
2. **Profile → confirm the API password** matches `ADMIN_API_PASSWORD`.
3. Leave the categories alone for now — they are created automatically when a feed is filed
   into one, which is what the OPML import in §3.4 does. Creating them by hand first is the
   same work twice.

> **"Allow API access" is already on.** It was enabled without the browser:
> `php cli/reconfigure.php --api-enabled`, then `./scripts/services.sh restart freshrss`.
> The restart matters — a running PHP worker keeps the old configuration in memory, so the
> API kept answering `503` until the service was bounced. Note also that `api_enabled` is a
> **system** setting: it lives at the root of `data/config.php`, not in the user's config.

### 2.3 Then these become possible

```bash
./scripts/seed_menubar_config.sh   # push URL + API password into Keychain/defaults
./scripts/healthcheck.sh           # expect no warnings at all
```

The first backup is **already taken** — see §3.3.

---

## 3. Left undone — the list

Ordered by what unblocks what. Nothing here is blocked except by §2.1, which is a single
command.

### 3.1 FreshRSS configuration (WS2) — one item left, and it blocks everything

- [x] **"Allow API access"** — enabled with `php cli/reconfigure.php --api-enabled` plus a
      service restart. Verified: `/reader/api/0/token` returns `401`, not `503`.
- [x] **The healthcheck's API probe** — it could never pass; it now probes a real route and
      the warning is gone.
- [ ] **Set the admin login** — `./scripts/set-admin-credentials.sh` (§2.1). Until this is
      run, no password works and every API call answers `401`.
- [ ] Log in at <http://127.0.0.1:8080> and confirm the API password under Profile.
- [ ] Categories (`Tech`, `Reading`, `Forums`, `Video`, `Social`, `Media`) — created as a
      side effect of the OPML import in §3.4 rather than by hand.
- [ ] `./scripts/seed_menubar_config.sh` — needs the API password, so it follows the login.

### 3.2 Menu bar app (WS5) — five known gaps, then acceptance

- [ ] **`.unread / total` text mode renders identically to `.unread`.** `UnreadSnapshot` has
      no total field and `FreshRSSClient.menuBarText` returns one string for both modes
      (`FreshRSSClient.swift:62`).
- [ ] **`tag/list` is never called.** `docs/menubar_app.md` §5 lists it as request 4;
      categories are derived from `user/-/label/…` unread-count entries instead.
- [ ] **`unauthorized` shows a generic Retry button**, but the doc promises a Settings button.
- [ ] **`unconfigured` has no action** — a static empty state.
- [ ] **`menuBarTextMode` is hardcoded to `"unread"`** in the seeder
      (`scripts/seed_menubar_config.sh:126`), so the setting is never seeded as a value.
- [ ] **Run the WS5 acceptance** (`implementation_plan.md` §WS5, five criteria). It has never
      been exercised, including the relaunch-after-`./scripts/services.sh stop` case.

### 3.3 Operations (WS7)

- [x] **First backup taken** — `freshrss-data-20260921-233937.tar.gz` (170 KB), a standalone
      `.sqlite3` copy and a `MANIFEST`. Verified to hold `apps/FreshRSS/data`,
      `apps/rss-bridge/config.ini.php` and `env`, and no upstream tooling.
- [x] **`backup.sh` was broken and is now fixed.** It named `FreshRSS/data` when the
      applications live under `private/apps/`, so `tar` aborted on its first target — and
      with its error output discarded, the failure looked exactly like a successful 4 KB
      backup. Paths are derived from the real locations now, and a partial archive is
      deleted rather than left for a restore to pick up.
- [ ] **Demonstrate the restore acceptance** — "a backup restored into a clean `data/`
      reproduces every subscription and category". Runnable for the first time; still not run.
- [ ] **`./scripts/install-youlag.sh`** — deferred deliberately until YouTube is actually in
      the feed list.

### 3.4 Sources (WS4) and taming (WS6)

- [ ] The 11 onboarding steps in `docs/source_catalog.md` §6 — **0 done**.
- [ ] **Supply the feed list (input A6)**, then run the guided onboarding session. This is the
      one input nothing else can substitute for.
- [ ] Run `./scripts/verify-feed.sh` per feed as it is added and record the result in
      `source_catalog.md` §8, whose register still holds its placeholder row.
- [ ] WS6: categories applied to every feed, then mute/hide/filter rules.
- [ ] Optional Discord webhook — `DISCORD_WEBHOOK_URL` is declared in `.env.example` and read
      by nothing; no webhook extension is installed.
- [ ] Instagram stays disabled (`ENABLE_INSTAGRAM=0`) until everything else works.

### 3.5 Documentation and script debt

- [x] ~~`docs/operations.md` §1 still reads instruction-shaped where it contrasts with Docker~~
      — reworded to lead with what a backup is.
- [x] ~~`docs/CHANGELOG.md` format example vs. the entries~~ — the header now names `0.0.1-1`.
- [ ] **`--help` output is still fragile by construction, though the four that were wrong are
      fixed.** 12 scripts print their own header via a hardcoded `sed -n '2,Np'` range. Audited
      against each header: `build.sh` printed a line of shell code (`set -euo pipefail`), and
      `restore.sh`, `services.sh` and `verify-feed.sh` cut off mid-sentence. All four now match
      their header, and all 12 were re-checked. The class of bug disappears entirely if the
      ranges are replaced by a helper that stops at the header's closing comment line.
- [ ] `docs/agent_scaffold_plan.md` — **deliberately untouched**, it is marked historical.

### 3.6 Resolved since this was written

- **All container-era residue is gone.** Four false statements in the app's own copy ("a
  Docker volume" that does not exist, and a stopped Docker daemon named as the failure
  cause), a wrong Youlag path, two documents using "volume" for a directory, the dead
  `.gitignore` rules, container hostnames used as env defaults, and the live `env` header
  — which had been advising `docker compose down -v`, a command that would have deleted
  every subscription. The app was rebuilt so the corrected copy is in the bundle; the
  binary no longer contains the string `docker`.
- The `.gitignore` "generated nginx + php-fpm config" / "unix sockets" comments are **gone**;
  only `scripts/backup.sh` still mentions the old tooling, correctly, as a note about what
  is *not* in the archive.
- The stale duplicate checkout is **deleted** (§5).

---

## 4. The password incident — read this

While implementing, a password prompt was added to `install.sh`. It blocked, and the
**next shell command's text was consumed by `read` as the answer**. The admin account was
therefore created with a shell command as its password, and that string was written into
`private/env` as `ADMIN_PASSWORD`.

Remediated the same session:

- password rotated to a fresh random value, never recorded → the account is locked;
- `ADMIN_PASSWORD` blanked in `private/env`;
- the prompt reverted — `install.sh` is non-interactive again and now **never** prompts;
- `scripts/set-admin-credentials.sh` added for the interactive part;
- `set_env_value()` added to `lib-common.sh` (value passes via the environment, so it
  never appears in `ps`; temp file + `mv`; mode preserved).

The account could not simply be deleted: FreshRSS refuses with *"default user must not be
deleted"*. Rotating was the alternative.

Nothing else was exposed: the string was never one of your secrets, the instance is
loopback-only, and API access is still off.

---

## 5. One hazard worth knowing about

1. ~~**A stale duplicate checkout** at `~/Documents/GitHub/black_glass_candle`~~ — **deleted
   2026-09-21.** It was a pure clone: same commit `c2d013c`, clean tree, no stashes, no
   unpushed commits, no unreachable objects, no `private/`, and the working tree differed
   from the live checkout only in `.DS_Store` files. `~/Documents/GitHub/` now contains only
   `glass_candle_tv`. It is reproducible from the remote if ever needed:
   `git clone https://github.com/afrogenesurvive/glass_candle_tv.git`.
2. **`~/Documents`, `~/Desktop` and `~/Downloads` are off-limits for anything launchd has
   to read.** The refresh job dies there with `Operation not permitted`, exit 126. The
   repo itself is fine under `~/Documents` (a terminal has the access launchd lacks); the
   data and the staged agent scripts are not, so both live in Application Support.
   `healthcheck.sh` FAILs if the data directory is ever put inside one of those folders,
   and warns if a stale in-repo `private/` reappears.

---

## 6. Repository state

Branch `0.0.1` at `c2d013c`; `main` was fast-forwarded to it and both are pushed. That
commit is the most recent one — **everything below is uncommitted**:

- 17 modified files, +265/−134: four Swift sources, five docs (this one included),
  `.gitignore`, `.env.example`, and six scripts — `backup.sh`, `build.sh`, `healthcheck.sh`,
  `restore.sh`, `services.sh`, `verify-feed.sh`
- no files added or deleted

It takes the usual wrap-up for this repo — manual secret scan, commit, push, fast-forward
`main`, switch back — because there is no `docs/safe/` pair, no `check-public-safety.mjs`,
no `package.json` and no release automation.

Three of the changes alter behaviour (the healthcheck probe, the backup path fix, and the
copy inside the app), so the commit message should say so rather than describing this as
documentation-only. One note for the scan: the diff touches `private/env` **only outside
this repository**, so nothing from that file can appear in the commit.

`docs/CHANGELOG.md` carries `[0.0.1-3]` for this work, and its format example now names
`0.0.1-1` to match the entries.

---

## 7. Practical note: the editor and terminal

The VS Code workspace is at `~/Documents/GitHub/glass_candle_tv` — the repo path — and
that is the right place for it: git, the editor and these scripts all run from a
terminal, which has the file access that launchd lacks. Personal state is not in the
workspace; address it absolutely when you need it:

```bash
open "$HOME/Library/Application Support/glass_candle_tv/private"
```
