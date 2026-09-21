# Operations Runbook

Day-two operations: backup, restore, upgrade, rotate, diagnose.

The feed database is the asset. Everything else here can be rebuilt from `.env` and this
repo in ten minutes. Read §1 before you need it.

---

## 1. Backup

```bash
./scripts/backup.sh              # backup now
./scripts/backup.sh --list       # show existing backups
```

Writes to `$BACKUP_DIR` (default `~/Backups/black_glass_candle`):

| Artefact | Contents |
| --- | --- |
| `freshrss-<ts>.sqlite3` | Users, subscriptions, categories, read/unread state, filters |
| `subscriptions-<ts>.opml` | Portable subscription list — restorable into *any* reader |
| `env-<ts>.enc` | Encrypted `.env` (skipped if `age` is unavailable) |
| `MANIFEST-<ts>.txt` | FreshRSS version, feed count, checksums |

Retention: `BACKUP_KEEP_DAYS`, default 30.

> **The OPML file is the important one.** An SQLite file restores this instance; an OPML
> file restores your subscriptions into anything. Keep both, and keep a copy off this Mac.

**Do a backup before:** adding more than a handful of feeds, upgrading, changing the
database backend, or `docker compose down -v`.

### Restore

```bash
./scripts/restore.sh                     # interactive: lists backups, asks which
./scripts/restore.sh <path-to-sqlite3>   # non-interactive
```

Restore stops the containers, replaces the database inside the `freshrss_data` volume,
and restarts.

**Verify a restore before you need it.** A backup you have never restored is a hypothesis,
not a backup. Once, deliberately:

```bash
docker compose down -v            # destroys everything
docker compose up -d
./scripts/restore.sh <latest>
```

If your subscriptions are back, you have a working backup. If you are not willing to run
this, you do not have a backup.

### OPML-only recovery

If the SQLite file is corrupt but the OPML survived:

1. `docker compose up -d`
2. Log in → Subscription management → **Import** → select the OPML
3. Recreate categories and re-apply mute/hide — these are **not** carried in OPML

---

## 2. Upgrade

```bash
./scripts/upgrade.sh             # backup, pull, recreate, health check
./scripts/upgrade.sh --dry-run   # show what would change
```

Pinned vs rolling:

| Setting | Behaviour |
| --- | --- |
| `freshrss/freshrss:latest` | Latest tagged release. **Recommended.** |
| `freshrss/freshrss:1.30.0` | Exact version. Use if an upgrade breaks something. |
| `freshrss/freshrss:edge` | Rolling. Breaks without warning. |

Youlag requires FreshRSS ≥ 1.30.0. If you pin an older version, YouTube mode stops
working.

**Rollback:** `git` does not track container images. Record the previous tag in
`MANIFEST-*.txt` before upgrading, then set it back and `docker compose up -d`.

---

## 3. Rotation

### `ADMIN_API_PASSWORD` (used by the menu bar app)

1. FreshRSS → Profile → API password → set new value
2. Update `ADMIN_API_PASSWORD` and `MENUBAR_API_PASSWORD` in `.env`
3. `./scripts/seed_menubar_config.sh`
4. Re-open the menu bar app

No restart required — the app re-authenticates on the next `401`.

### `RSSBRIDGE_TOKEN`

1. `openssl rand -hex 24` → update `RSSBRIDGE_TOKEN` in `.env`
2. `./scripts/gen-rssbridge-config.sh` and restart RSS-Bridge
3. **Every existing bridged subscription URL now contains the old token and will 401.**
   Update the feed URL for each bridged feed in FreshRSS subscription management.

Step 3 is the expensive part. Treat this as a break-glass action.
### Compromised credential

| Credential | Action |
| --- | --- |
| `GITHUB_TOKEN` | Revoke at GitHub → Settings → Developer settings → PATs. Issue a new one. |
| `CLOUDFLARE_TUNNEL_TOKEN` | Delete the tunnel in the Zero Trust dashboard. Create a new one. |
| `DISCORD_WEBHOOK_URL` | Delete the webhook, create a new one. |
| Instagram burner cookies | Log out of the burner everywhere. Change its password. Re-paste cookies. |
| `ADMIN_PASSWORD` (web UI) | Change in the web UI. If the instance is exposed, rotate `TZ`-independent things too — check `docker compose logs freshrss` for unexpected source IPs. |
| `.env` committed to git | See §6. |

---

## 4. Diagnostics

```bash
./scripts/healthcheck.sh          # one-shot status of the whole stack
```

What it checks: container state, port reachability, FreshRSS HTTP response, RSS-Bridge
HTTP response, freshness of the last feed pull, and disk usage of the volumes.

### Decision table

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Feeds never update | `CRON_MIN` empty | Set `CRON_MIN=13,43`, restart |
| Feeds update at the wrong time of day | `TZ` wrong | Fix `TZ`, restart |
| Bridged feeds fail to fetch | `INTERNAL_HOST_ALLOWLIST` missing | Must include `rss-bridge:80` |
| All feeds fine, one bridged feed empty | Bridge broken or selector rotted | Test the bridge URL directly with curl |
| `Service Unavailable` from the API | API access toggle off | FreshRSS → Authentication → "Allow API access" |
| Menu bar shows *stack is down* | Docker not running | `docker compose up -d` |
| Menu bar shows *password rejected* | API password mismatch | Re-run `seed_menubar_config.sh` |
| Container restarts in a loop | Volume permissions | `docker compose logs freshrss \| tail -50` |
| Disk filling | Uncapped container logs | Confirm `logging.options.max-size` is set |
| Everything 500s after upgrade | Version incompatibility | Pin the previous tag, restore backup |

### Logs

```bash
docker compose logs -f --timestamps freshrss
docker compose logs -f --timestamps rss-bridge
docker compose ps
```

---

## 5. Routine maintenance

| Cadence | Task |
| --- | --- |
| Weekly | Glance at the menu bar. A source that has been empty for a week is broken, not quiet. |
| Monthly | `./scripts/backup.sh` and confirm it exists. Check Youlag for updates. |
| Quarterly | Restore a backup into a scratch directory to prove it works. Re-check forum selectors. |
| On breakage | Instagram cookies, forum selectors, Reddit rate limits. See [`source_catalog.md`](./source_catalog.md). |

---

## 6. Incident: `.env` committed to git

If a secrets file ever reaches git, **the secrets are already compromised.** Rewriting
history does not un-leak them. Rotate first, clean second.

1. **Rotate everything in that file.** Use the table in §3. Assume full compromise.
2. Confirm the ignore rule works:
   `git check-ignore -v --no-index .env`
3. Remove from the index: `git rm --cached .env`
4. If it was pushed, clean history with `git filter-repo` and force-push with
   `git push --force-with-lease`.
5. Consider whether the repo is public. If it is, assume crawling happened within minutes.

The `.gitignore` in this repo covers `.env` and its variants. Note that plain
`git check-ignore` **silently skips tracked paths**, so it reports nothing for exactly the
file you are worried about — always pass `--no-index` when validating rules.

---

## 7. Destroying the stack

```bash
docker compose down              # stop, keep all data
docker compose down -v           # stop AND delete volumes — subscriptions gone
```

`down -v` removes `freshrss_data`, which is everything. Run `./scripts/backup.sh` first.
There is no undo.
