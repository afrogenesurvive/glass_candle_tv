# Inputs Required

Everything this project needs from you, how to obtain it, and what happens if it leaks.

**How to use this document:** work top to bottom. Section A is decisions only you can
make. Section B is secrets you invent. Section C is credentials you have to go and
fetch. Section D is the source list. Fill in `private/env` as you go — every row names
the variable it maps to.

**Legend:** 🔴 full account/instance access · 🟠 scoped credential · 🟡 rate-limit
or convenience · 🟢 not secret

---

## A. Decisions only you can make

These have no "correct" answer, but the whole stack's defaults depend on them.

| # | Input | `private/env` variable | Notes |
| --- | --- | --- | --- |
| A1 | Your IANA timezone | `TZ` | e.g. `America/Jamaica`. Full list at [php.net/timezones](https://www.php.net/timezones). **A wrong value does not error** — it silently shifts every date, and `today` filters return the wrong day. |
| A2 | Where the stack runs | `DEPLOY_TARGET` | `local` (this Mac), `vps`, or `pi`. Determines whether you need remote access at all. |
| A3 | Ports | `FRESHRSS_PORT`, `RSSBRIDGE_PORT` | 8080 / 3000 unless taken. `lsof -i :8080` to check. |
| A4 | Do you read on other devices? | `SERVER_DNS`, `REVERSE_PROXY` | **No** → stay local, skip section C5 entirely. **Yes** → you need a hostname, HTTPS, and the `Allow API access` toggle. |
| A5 | Backup destination and retention | `BACKUP_DIR`, `BACKUP_KEEP_DAYS` | Where `backup.sh` writes, and where `restore.sh` and `healthcheck.sh` look. Keep it outside this repo: `private/` is gitignored, but a `git clean -xdf` would take your backups with it. Defaults to `~/Backups/black_glass_candle`, 30 days. |
| A6 | **Your feed list** | `FORUM_TARGETS` + web UI | The actual sources. See [`source_catalog.md`](./source_catalog.md). |

---

## B. Secrets you invent

| # | Input | `private/env` variable | How to generate |
| --- | --- | --- | --- |
| B1 | Web UI login password | `ADMIN_PASSWORD` | Your password manager |
| B2 | FreshRSS **API** password | `ADMIN_API_PASSWORD` | `openssl rand -base64 24` |
| B3 | RSS-Bridge shared token | `RSSBRIDGE_TOKEN` | `openssl rand -hex 24` |

### On B2 specifically

This is a **separate** password from B1 and should stay separate. The FreshRSS docs put
it plainly: it *"may be used in less safe situations than the main password, and does
not grant access to as many things."*

It will live in the macOS Keychain on your machine and in any mobile client you
configure. Treat it as a device credential, not an account credential. Minimum 8
characters.

**To set it:** FreshRSS → Administration → Authentication → enable **"Allow API access
(required for mobile apps)"**. Then Profile → **"API password"**.

> ⚠️ Enabling API access is a two-step job. The API returns `Service Unavailable` until
> the Authentication toggle is on, even if the API password is already set.

**To verify it works:** click the `/api/` link next to the API password field, then
"Check full server configuration". You want `PASS`.

### On B3 specifically

This token is appended to every generated feed URL as `&token=...`. Anyone holding it
can read every feed you have configured. It is required precisely because RSS-Bridge
without a token is an open, unauthenticated feed generator that will happily fetch
arbitrary URLs on behalf of anyone who finds the port.

---

## C. Credentials you must go and obtain

### C1 — Instagram burner cookies 🔴

Full account credentials. **Use a burner account, never your personal one.**

Instagram has no public feed API, so the only route to your own feed is to replay a
logged-in browser session. That means copying live session cookies into a config file.

| Value | `private/env` variable | Where to find it |
| --- | --- | --- |
| `sessionid` | `INSTAGRAM_SESSIONID` | DevTools → Application → Storage → Cookies → `https://www.instagram.com` |
| `ds_user_id` | `INSTAGRAM_DS_USER_ID` | same |

`csrftoken` is often cited as a third value to copy. This RSS-Bridge release does not use
it: `InstagramBridge` declares only `session_id` and `ds_user_id`, so
`INSTAGRAM_CSRFTOKEN` is accepted and then ignored. Copying it is harmless but pointless.

**Expiry:** these die whenever the burner logs out or changes password, and Meta
rotates sessions on their own schedule. Expect to re-paste them every few weeks.

**Handling rules:**
- Keep `ENABLE_INSTAGRAM=0` until you actually want it. Nothing else depends on it.
- Never re-use the burner's email or password anywhere else.
- If the burner's password is the same as anything else you own, change it now.

> The bridge failing shows up as an empty Instagram category. It will not affect any
> other feed. That isolation is deliberate — see the risk table in the plan.

### C2 — GitHub personal access token 🟠

Used by the GitHub bridges (`GithubReleaseBridge`, `GithubTrendingBridge`) to lift the
anonymous rate limit of 60 requests/hour.

**Often unnecessary.** `https://github.com/<owner>/<repo>/releases.atom` needs no token,
has no rate limit, and cannot break when GitHub changes its markup. Reach for a token only
when you want an org-wide feed that Atom cannot express.

1. GitHub → Settings → Developer settings → **Personal access tokens (classic)**
2. Generate new token, scopes: **`public_repo`** and **`read:org`**. Nothing else.
3. Set a short expiry. This token is read-only; the scopes above cannot write code,
   change settings, or reach private repos.

Alternatively use a fine-grained token with read-only *Metadata* + *Contents*.

`private/env` variable: `GITHUB_TOKEN`. Emitted as `[GithubReleaseBridge] token` in the
generated RSS-Bridge config.

**If it leaks:** revoke it. It grants read access to public repository data under your
identity, which is a rate-limit and attribution problem, not a code-theft problem —
provided you did not add extra scopes.

### C3 — Reddit application credentials � NOT SUPPORTED

**Do not go and fetch these.** This RSS-Bridge release cannot use them: `RedditBridge`
declares no configurable options at all, so `REDDIT_CLIENT_ID` and `REDDIT_CLIENT_SECRET`
reach no code path and no bridge. They are still present in `.env.example` so an existing
file does not silently lose lines.

If `RedditBridge` starts returning 429s:

1. Set `RSSBRIDGE_USER_AGENT` to a normal browser string. That resolves most cases.
2. Otherwise drop the sub. Reddit actively fights unauthenticated access, and
   [`source_catalog.md`](./source_catalog.md) treats removing it as a legitimate
   outcome rather than a failure.

### C4 — Forum CSS selectors 🟢

Forums have no feed and no bridge, so they are scraped by CSS selector. Not secret, but
fiddly, and the selectors break when a forum restyles.

For each forum, open a **thread listing page** (not a single thread) and use DevTools →
Inspect to find:

| Field | Meaning | Typical value |
| --- | --- | --- |
| `ITEM_SELECTOR` | One element per thread | `.structItem` |
| `TITLE_SELECTOR` | The title text | `.structItem-title a` |
| `LINK_SELECTOR` | The link element | `.structItem-title a` |
| `DATE_SELECTOR` | The timestamp | `time` |

Format, one forum per line in `FORUM_TARGETS`:

```
NAME|URL|ITEM_SELECTOR|TITLE_SELECTOR|LINK_SELECTOR|DATE_SELECTOR
```

Blank `DATE_SELECTOR` is allowed if the listing has no dates.

**Verify immediately** — a wrong selector returns a feed with zero items, which looks
identical to a forum with no new posts. Run
`./scripts/verify-feed.sh "<the bridged URL, token included>"` before subscribing, and
record the result in [`source_catalog.md`](./source_catalog.md) §8.

### C5 — Cloudflare Tunnel token 🔴

*Only if `REVERSE_PROXY=cloudflared`.* Skip entirely for local-only use.

Cloudflare dashboard → Zero Trust → Networks → Tunnels → create → copy the connector
token. Requirement: you already own the domain and it is on Cloudflare.

`private/env` variable: `CLOUDFLARE_TUNNEL_TOKEN`

**If it leaks:** anyone with the token can run a connector for your tunnel and route
traffic to services on your network. Revoke in the dashboard — the token is the only
credential, so revocation is immediate and total.

> For personal remote access, Tailscale is the lower-risk option and is already in use
> elsewhere in your toolchain: it is a private mesh, so FreshRSS is never exposed to the
> public internet and there is no public DNS record to find.

### C6 — Discord webhook URL 🟠

*Only if you want article notifications.* Optional.

Discord → channel settings → Integrations → Webhooks → New Webhook → Copy URL.

`private/env` variable: `DISCORD_WEBHOOK_URL`

**If it leaks:** anyone can post messages into that channel. Not a data risk, an
annoyance risk. Delete and recreate the webhook to revoke.

---

## D. Feed list (the real input)

The technology is the easy part. What makes this yours is the list of things you
actually want to read. Gather these before starting WS4:

| Source type | What to collect | Counts toward |
| --- | --- | --- |
| YouTube channels | Channel handle or URL. The bridge resolves the channel ID. | `Video` category |
| Bear Blog / personal blogs | Site URL. Most have native RSS — check for `/feed` first. | `Reading` |
| Hacker News | Nothing. `https://hnrss.org/frontpage` with optional query params. | `Tech` |
| Lemmy | Instance + community, e.g. `lemmy.ml/c/technology` | `Tech` |
| Reddit | Subreddit names | `Tech` / `Reading` |
| GitHub | Specific repos, or an org | `Tech` |
| Forums | URL + CSS selectors (see C4) | `Forums` |
| Instagram | Burner account + accounts you follow | `Social` |

**A note on scope.** More sources is not better here. Every feed you add is permanent
maintenance: it can break, rot, or start producing noise. The upstream scaffold's own
advice applies — 15 sources you read is worth more than 60 you skim, and the "tame the
flow" stage (WS6) only works if the raw list is small enough to reason about.

---

## E. Completion checklist

Copy this into your own notes and tick as you go.

```
[ ] A1  TZ                      = ________________________
[ ] A2  DEPLOY_TARGET           = ________________________
[ ] A3  ports                   = ______ / ______
[ ] A4  remote access?          = yes / no
[ ] A5  BACKUP_DIR              = ________________________
[ ] A6  feed list gathered      = ____ sources

[ ] B1  ADMIN_PASSWORD          set
[ ] B2  ADMIN_API_PASSWORD      set   (>= 8 chars)
[ ] B3  RSSBRIDGE_TOKEN         set
[ ]     api access toggle ON          <- easy to forget
[ ]     /api/ config check      = PASS

[ ] C1  instagram burner        = set / skipped (ENABLE_INSTAGRAM=0)
[ ] C2  GITHUB_TOKEN            = set / skipped
[ ] C3  reddit credentials      = N/A, unsupported in this release
[ ] C4  forum selectors         = ____ forums, all verified non-empty
[ ] C5  remote access creds     = set / skipped (local only)
[ ] C6  discord webhook         = set / skipped

[ ] D   every source subscribed and verified
```

---

## F. Handling rules

1. `private/env` lives **outside the checkout**, at
   `~/Library/Application Support/glass_candle_tv/private/env` — see *Where the data
   lives* in [`operations.md`](./operations.md) for why. `private/` is gitignored as well,
   so a stray copy inside the repository cannot be committed either.
2. Never paste `private/env` contents into a doc, an issue, a screenshot, or a chat
   message.
3. Back up `private/env` to your password manager, not to a synced folder.
4. `RSSBRIDGE_TOKEN` and `ADMIN_API_PASSWORD` appear in URLs and logs. If you ever paste
   a feed URL while debugging, treat it as having leaked.
5. Rotating `ADMIN_API_PASSWORD` requires re-seeding the menu bar app:
   `scripts/seed_menubar_config.sh`
6. Anything you paste into `INSTAGRAM_*` is a live capability to act as that account.
   Burner only. This is the single highest-risk input in the project.
