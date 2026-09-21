# Operations Runbook

Day-two operations: backup, restore, upgrade, rotate, diagnose.

**The feed database is the asset.** Everything else here can be rebuilt from
`private/env` and this repository in ten minutes. Read §1 before you need it.

---

## Where the data lives

Not in the repository. Everything personal is under `$BGC_PRIVATE`:

```
~/Library/Application Support/glass_candle_tv/private/
```

with a sibling `agent/` holding the copies of `refresh-feeds.sh` and `lib-common.sh` that
launchd executes.

This is a macOS constraint, not a preference. `~/Documents`, `~/Desktop` and
`~/Downloads` are TCC-protected, and a process started by `launchd` cannot read a file
there: the read fails with `Operation not permitted` and the agent records exit 126 —
indistinguishable from a job that found nothing to do. The refresh agent is exactly such
a job, and it has to read its own script and the data. A symlink out of `~/Documents`
does not help; TCC resolves the target and denies that too. The measurement is recorded
next to the paths in `scripts/lib-common.sh`.

The consequence is narrower than it sounds: the repository may live anywhere, including
`~/Documents/GitHub/…`, because `git`, your editor and these scripts all run from a
terminal, which does have access. Only what a scheduled job must *read* has to move.
Moving the repo therefore needs no path edits at all; the scripts resolve the data
directory from `BGC_PRIVATE`, which can also be overridden for a throwaway run.

To relocate the data:

```bash
DATA="$HOME/Library/Application Support/glass_candle_tv"
./scripts/services.sh stop
mkdir -p "$DATA"
mv "<old place>/private" "$DATA/private"
./scripts/services.sh install      # rewrites the plists, stages the agent scripts
./scripts/healthcheck.sh
```

`services.sh install` is what deploys an edit to `refresh-feeds.sh`: launchd runs a copy
of it from `agent/`, because it cannot read the repo. `healthcheck.sh` reports a stale
copy, so the two cannot drift silently.

---

## 1. Backup

```bash
./scripts/backup.sh              # backup now
./scripts/backup.sh --list       # show existing backups
```

Writes to `private/backups/`:

| Artefact | Contents |
| --- | --- |
| `freshrss-data-<ts>.tar.gz` | `data/` (subscriptions, categories, articles, read state) + `env` + the bridge config |
| `freshrss-<ts>.sqlite3` | A standalone copy of the database, for inspecting or restoring one thing |
| `MANIFEST-<ts>.txt` | Host, checksum, feed count, PHP version, retention |

Retention: `BACKUP_KEEP_DAYS`, default 30.

Natively this is a plain `tar` of a folder. There is no VM disk image to go through and no
`docker run` needed to extract a volume — you can open the result in Finder. The freshrss
service is stopped for the duration: its SQLite database runs in write-ahead-log mode, and
copying the files mid-write risks a torn snapshot. A clean shutdown checkpoints the WAL
first. The outage is a few seconds.

> **The OPML export is the portable artefact.** An archive restores *this* instance; an
> OPML restores your subscriptions into anything. Get one from the web UI
> (*Subscription management → Export*) and keep a copy off this machine.

**Do a backup before:** adding more than a handful of feeds, upgrading, or changing
anything in `private/etc/`.

### Restore

```bash
./scripts/restore.sh                     # interactive: lists backups by size and date
./scripts/restore.sh <archive.tar.gz>    # non-interactive
```

The current `data/` directory is **moved aside**, not deleted, to
`data.pre-restore-<timestamp>`. A mistaken restore is then a single `mv` back.

**Verify a restore before you need it.** A backup you have never restored is a hypothesis,
not a backup. Once, deliberately:

```bash
./scripts/restore.sh <latest>
```

If your subscriptions come back, you have a working backup. If you are not willing to run
that, you do not have a backup.

---

## 2. Upgrade

```bash
./scripts/upgrade.sh             # backup, git pull, restart, verify
./scripts/upgrade.sh --dry-run   # show what would change
```

Both apps are git checkouts in `private/apps/`, so an upgrade is `git pull` rather than
pulling container images. `--ff-only` is used deliberately: a merge commit would mean the
clone has local edits, which these scripts never make.

**Your data is untouched by an upgrade** — it lives in `data/`, a sibling of the code.
That separation is the main reason the layout survived the move away from Docker.

**Rollback:** Docker used to record image digests for you; git has no equivalent unless
you write it down. The script prints the current commit hashes before pulling. To go back:

```bash
git -C private/apps/FreshRSS log --oneline -5
git -C private/apps/FreshRSS checkout <commit>
./scripts/services.sh restart freshrss
```

---

## 3. Rotation

### `ADMIN_API_PASSWORD` (used by the menu bar app)

1. FreshRSS → Profile → API password → set the new value
2. Update `ADMIN_API_PASSWORD` and `MENUBAR_API_PASSWORD` in `private/env`
3. `./scripts/seed_menubar_config.sh`
4. Re-open the menu bar app

No restart needed — the app re-authenticates on the next `401`.

### `RSSBRIDGE_TOKEN`

1. `openssl rand -hex 24` → update `RSSBRIDGE_TOKEN` in `private/env`
2. `./scripts/gen-configs.sh`
3. `./scripts/services.sh restart rssbridge`

> ⚠️ **Every existing bridged subscription URL still contains the old token**, and will now
> return `401`. Update the feed URL for each bridged feed in FreshRSS subscription
> management. Treat this as a break-glass action.

### Compromised credential

| Credential | Action |
| --- | --- |
| `GITHUB_TOKEN` | Revoke at GitHub → Settings → Developer settings → PATs. Issue a new one. |
| `DISCORD_WEBHOOK_URL` | Delete the webhook, create a new one. |
| Instagram burner cookies | Log out of the burner everywhere. Change its password. Re-paste cookies. |
| `ADMIN_PASSWORD` (web UI) | Change it in the web UI. Check `private/logs/` for unexpected requests first. |
| `private/env` committed to git | See §6. |

---

## 4. Diagnostics

```bash
./scripts/healthcheck.sh          # one-shot status of everything
./scripts/healthcheck.sh --quiet  # only problems
```

It checks: layout and privacy invariants, config sanity, launchd agent state, both HTTP
endpoints, **that the data directory is outside the web document root**, that RSS-Bridge
rejects a bad token, refresh history, backup presence, disk space, and whether PHP is
pinned.

### Decision table

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Feeds never update | The refresh agent is failing to start | `tail -20 "$DATA/private/logs/refresh-stderr.log"` (with `DATA="$HOME/Library/Application Support/glass_candle_tv"`). `Operation not permitted` there means launchd cannot read the script or the data — check the location, then `./scripts/services.sh install` |
| Feeds never update, no error anywhere | The agent is running an older copy of `refresh-feeds.sh` | Edit in the repo, then `./scripts/services.sh install` to stage it. `./scripts/healthcheck.sh` reports a stale copy |
| Feeds update at the wrong time | `TZ` wrong | Fix `TZ` in `private/env`, then `./scripts/services.sh install` |
| Service not answering | Agent crashed or never loaded | `./scripts/services.sh status`, then `restart` |
| `refresh` exits non-zero | No admin account yet, or the FreshRSS CLI errored | `cat private/logs/refresh.log` — each block names the entry point and user it tried |
| `Address already in use` in the logs | Something else holds the port | `lsof -nP -iTCP:8080 -sTCP:LISTEN` |
| Bad token returns `200` | **`config.ini.php` is not in the RSS-Bridge root** | `./scripts/gen-configs.sh` — no restart needed, the config is read per request |
| Bridged feed is empty | Bridge name does not exist, or the site changed | Verify the name against `private/apps/rss-bridge/bridges/` |
| Menu bar shows *stack is down* | A service is not running | `./scripts/services.sh status` |
| Menu bar shows *password rejected* | API password mismatch | `./scripts/seed_menubar_config.sh` |
| Everyone gets a 500 after upgrade | Schema migration pending | Open the web UI and follow the prompt |
| Disk filling | Logs or refresh output | Check `private/logs/`, retention in `private/backups/` |

> **`restart` does not re-read `private/env`.** `TZ`, `CRON_MIN`, the ports and the worker
> count are baked into the launch agent plist XML when it is generated, so
> `./scripts/services.sh restart` reloads the *existing* file and silently keeps the old
> values. After changing any of them run `./scripts/services.sh install`. The `restart`
> command warns when `private/env` is newer than the plists.

### Logs

```bash
DATA="$HOME/Library/Application Support/glass_candle_tv"
tail -f "$DATA/private/logs/freshrss-stderr.log"   # the PHP server's own output
tail -f "$DATA/private/logs/rssbridge-stderr.log"
tail -f "$DATA/private/logs/refresh.log"           # one block per refresh
./scripts/services.sh status                       # agent state + HTTP codes
```

### launchd

```bash
launchctl print gui/$(id -u)/com.afrogenesurvive.glass-candle-tv.freshrss
```

A service that is `loaded` but not `running` is usually crash-looping; `ThrottleInterval`
is 10s, so the logs will show repeated startup attempts.

---

## 5. Routine maintenance

| Cadence | Task |
| --- | --- |
| Weekly | Glance at the menu bar. A source that has been empty for a week is broken, not quiet. |
| Monthly | `./scripts/backup.sh`. Check Youlag for updates. |
| Quarterly | Restore a backup to prove it works. Re-check forum CSS selectors. |
| On breakage | Instagram cookies, forum selectors, Reddit rate limits. See [`source_catalog.md`](./source_catalog.md). |

### Pinning PHP

The `php` Homebrew formula is not pinned by default, so `brew upgrade` can move PHP under
the running services and they will fail to restart.

```bash
brew pin php      # hold the version currently verified against this stack
```

`healthcheck.sh` warns while this is unpinned.

---

## 6. Incident: `private/env` committed to git

If a secrets file reaches git, **the secrets are already compromised.** Rewriting history
does not un-leak them. Rotate first, clean second.

1. **Rotate everything in that file.** Use the table in §3.
2. Confirm the ignore rule works: `git check-ignore -v --no-index private/env`
3. Remove from the index: `git rm --cached private/env`
4. If it was pushed, clean history with `git filter-repo`, then
   `git push --force-with-lease`.
5. The repository is **public**. Assume crawling happened within minutes.

The root `.gitignore` covers `private/` as a single rule, and the live file is not in the
repo at all (see *Where the data lives* above), so a leak means a copy was made into the
repository — which the rule still catches. Note that plain `git check-ignore` **silently
skips tracked paths** — always pass `--no-index` when validating rules, or it reports a
false all-clear on precisely the file you are worried about.

---

## 7. Stopping and removing

```bash
./scripts/services.sh stop              # stop everything, keep all data
./scripts/services.sh uninstall         # unload + delete the launch agents
```

`uninstall` removes only the launchd plists. **Nothing in the data directory is
deleted** — your data survives, and `./scripts/install.sh` brings it all back.

To delete the data as well:

```bash
DATA="$HOME/Library/Application Support/glass_candle_tv"
rm -rf "$DATA/private/apps" "$DATA/private/backups"   # data and cloned code
```

There is no undo. Run `./scripts/backup.sh` first.
