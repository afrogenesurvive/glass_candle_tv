# Handover — what is left undone

Written 2026-09-21, at the end of a long working session. The stack now runs; it has
**nothing to read yet**, because there is no usable admin login. That is the single
blocker, and it is one command plus a few clicks.

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
| `healthcheck.sh` | 0 failures, 4 warnings — all from the missing login and no backups |
| FreshRSS installed | `data/config.php` exists; account `admin` exists |
| `php` formula | pinned |

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
2. **Administration → Authentication → enable "Allow API access".** There is no CLI for
   this; the API returns `503` until the toggle is on, even with the API password set.
3. **Profile → set/confirm the API password** (should already match `ADMIN_API_PASSWORD`).
4. Create six categories: `Tech`, `Reading`, `Forums`, `Video`, `Social`, `Media`.

### 2.3 Then these become possible

```bash
./scripts/seed_menubar_config.sh   # push URL + API password into Keychain/defaults
./scripts/backup.sh                # FIRST backup — do this before adding feeds
./scripts/healthcheck.sh           # expect the API warning to clear
```

---

## 3. Left undone — code and docs

### 3.1 Menu bar app (WS5)

- **`.unread / total` text mode renders identically to `.unread`** — `UnreadSnapshot` has
  no total field, and `FreshRSSClient.menuBarText` returns the same string for both.
- **`tag/list` is never called.** `docs/menubar_app.md` §5 lists it as request 4;
  categories are instead derived from `user/-/label/…` unread-count entries.
- **`unauthorized` shows a generic Retry button**, but the doc promises a Settings button.
- **`unconfigured` has no action** — a static empty state.
- **`menuBarTextMode` is hardcoded to `"unread"`** in the seeder, so the setting is never
  seeded as a starting value.
- **WS5 acceptance has never been run** (`implementation_plan.md` §WS5, five criteria),
  including the relaunch-after-`services.sh stop` case.

### 3.2 Feed onboarding (WS4) and taming (WS6)

- 0 of 11 checklist steps in `docs/source_catalog.md` §6.
- The guided session was planned but never started: needs your feed list (input A6).
- `scripts/verify-feed.sh` exists and works — use it per feed, record results in
  `source_catalog.md` §8 (`Feed register`), which currently holds a placeholder row.
- WS6 mute/hide/filter rules, and the optional Discord webhook, are untouched. Note
  `DISCORD_WEBHOOK_URL` is read by nothing and no webhook extension is installed.

### 3.3 Operations (WS7)

- **No backup has ever been taken.** `private/backups/` is empty.
- **The restore acceptance is therefore unrunnable** — "a backup restored into a clean
  `data/` reproduces every subscription and category" has never been demonstrated.
- `BACKUP_DIR` now works (`~/Backups/black_glass_candle`), but that directory does not
  exist yet; `backup.sh` creates it.
- Youlag is not installed (`./scripts/install-youlag.sh`). Deferred deliberately until
  YouTube is actually in the feed list.

### 3.4 Remaining documentation drift

- `.gitignore` comments around lines 24–26 still describe "generated nginx + php-fpm
  config" and "unix sockets, pid files" — neither exists in this stack.
- `docs/operations.md` §1 still reads instruction-shaped where it contrasts with Docker
  ("no `docker run` needed to extract a volume").
- `docs/CHANGELOG.md` documents the format as `<branch>-<n>`, but the first entry is
  `[0.0.1-1]` while the current branch is `main`. Decide which is authoritative.
- `docs/agent_scaffold_plan.md` is **deliberately untouched** — it is marked historical.
- **`--help` output is fragile by construction.** Each script prints its own header via a
  hardcoded line range (`sed -n '2,18p'` appears in a dozen files). Adding a line to a
  header silently truncates the help text — which happened to `install.sh` this session
  and was fixed by widening the range. A range that stops at the closing comment line
  would make the whole class of bug go away.

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

## 5. Two hazards worth knowing about

1. **A stale duplicate checkout** exists at `~/Documents/GitHub/black_glass_candle`. Same
   commits, no `private/`, and it holds the **pre-fix** scripts — including the inert bridge
   allowlist and the healthcheck that reported a dead refresh job as PASS. Do not run
   anything from there. It is a candidate for deletion.
2. **`~/Documents`, `~/Desktop` and `~/Downloads` are off-limits for anything launchd has
   to read.** The refresh job dies there with `Operation not permitted`, exit 126. The
   repo itself is fine under `~/Documents` (a terminal has the access launchd lacks); the
   data and the staged agent scripts are not, so both live in Application Support.
   `healthcheck.sh` FAILs if the data directory is ever put inside one of those folders,
   and warns if a stale in-repo `private/` reappears.

---

## 6. Uncommitted work

Branch `0.0.1`. All of the above session's changes are **uncommitted**:

- 19 modified files (8 scripts, `.gitignore`, `README.md`, `.env.example`, 5 docs, 1 Swift
  file)
- 3 new untracked files: `scripts/verify-feed.sh`, `scripts/set-admin-credentials.sh`,
  `docs/HANDOVER.md`

A secret scan of the full diff found no token-shaped strings, no private keys and no
absolute `/Users/` paths, and `private/` is still covered by `.gitignore`. It is safe to
commit through your normal `/save_progress` flow.

Note that `docs/CHANGELOG.md` is the public changelog and now holds `[0.0.1-2]` for the
data-directory split. Its header still documents the format with `main-1` as the example
while the entries themselves are named after `0.0.1` — decide which is authoritative
(§3.4).

---

## 7. Practical note: the editor and terminal

The VS Code workspace is at `~/Documents/GitHub/glass_candle_tv` — the repo path — and
that is the right place for it: git, the editor and these scripts all run from a
terminal, which has the file access that launchd lacks. Personal state is not in the
workspace; address it absolutely when you need it:

```bash
open "$HOME/Library/Application Support/glass_candle_tv/private"
```
