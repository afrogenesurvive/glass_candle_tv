# Source Catalog

One row per source: how to get it, whether it has a native feed, how it breaks, and what
to do when it does.

**Rule:** add a source only if you will actually read it. Every entry is permanent
maintenance. Fifteen feeds you read beats sixty you skim.

---

## 1. Native feeds — no bridge needed

These have real RSS/Atom. Prefer them: no scraping, no breakage, no token.

| Source | Feed URL | Category | Notes |
| --- | --- | --- | --- |
| Hacker News front page | `https://hnrss.org/frontpage` | Tech | Tunable: `?points=100` for high-signal only, `?count=30` |
| Hacker News, best comments | `https://hnrss.org/bestcomments?points=100` | Tech | High signal-to-noise |
| Bear Blog | `<site>/feed` | Reading | Convention is `/feed`; some use `/blog/feed` |
| Most personal blogs | `<site>/feed`, `/rss`, `/atom.xml`, `/index.xml` | Reading | Try in that order |
| GitHub releases | `https://github.com/<owner>/<repo>/releases.atom` | Tech | No token, no bridge, no rate limit — **prefer this over any GitHub bridge** |
| GitHub commits | `https://github.com/<owner>/<repo>/commits/<branch>.atom` | Tech | Same |
| Most blogs on Substack/Ghost/WordPress | `<site>/feed` | Reading | |
| YouTube channels | `https://www.youtube.com/feeds/videos.xml?channel_id=UC…` | Video | See §2 for finding the ID |

> **Try the native feed before reaching for a bridge.** `releases.atom` is strictly better
> than any GitHub bridge: no token, no rate limit, and it cannot break when GitHub changes
> page markup.

---

## 2. YouTube

No API key, no login, no Google account.

1. Find the channel ID: the channel page HTML contains `"channelId":"UC…"`, or use any
   public channel-ID lookup.
2. Subscribe to `https://www.youtube.com/feeds/videos.xml?channel_id=UC…`
3. Install **Youlag** (see §5) to get a video-shaped layout instead of a list of links.

| | |
| --- | --- |
| Bridge needed | No |
| Credentials | None |
| Breaks when | Almost never — this is an official, stable endpoint |
| Fallback | `YoutubeBridge` in RSS-Bridge |

---

## 3. Bridged sources

These need RSS-Bridge. All require `&token=$RSSBRIDGE_TOKEN`.

### Reddit

| | |
| --- | --- |
| Bridge | `RedditBridge` |
| Example | `/bridge=RedditBridge&r=<sub>&f=hot&format=Atom` |
| Breaks when | Reddit rate-limits the host IP |
| First fix | Set `RSSBRIDGE_USER_AGENT` to a normal browser string |
| Second fix | Supply `REDDIT_CLIENT_ID` / `REDDIT_CLIENT_SECRET` (see inputs doc C3) |
| Last resort | Drop the sub. Reddit actively fights this. |

> Treat Reddit as the least reliable source in the stack. If it becomes a chore, removing
> it is a legitimate outcome — the goal is less algorithmic input, and Reddit is one.

### Lemmy

| | |
| --- | --- |
| Bridge | **None ships in this RSS-Bridge release.** `LemmyBridge` does not exist, despite appearing in many guides. |
| Check first | Whether your instance exposes a feed for the community directly |
| Fallback | `CssSelectorBridge` against the community page |
| Notes | Instance must allow anonymous reads |

> Do not add a bridge name you have not confirmed. RSS-Bridge ignores unknown names
> silently, so a subscription to a non-existent bridge simply never returns items.

### GitHub (orgs and multi-repo)

| | |
| --- | --- |
| Bridge | **`GitHubBridge` does not exist.** The real names are `GithubReleaseBridge`, `GithubTrendingBridge`, `GithubSearchBridge`, `GithubPullRequestBridge`, `GithubIssueBridge`. |
| Credentials | `GITHUB_TOKEN` (raises 60/hr → 5000/hr) |
| **Prefer** | `releases.atom` / `commits.atom` for single repos — no token, no rate limit, and they cannot break when GitHub changes its markup |
| Use a bridge only | When you want an org-wide feed that Atom cannot express |

### Instagram

| | |
| --- | --- |
| Bridge | `InstagramBridge` |
| Credentials | Burner account cookies — the highest-risk input in the project |
| Enabled | Only when `ENABLE_INSTAGRAM=1` |
| Breaks when | Constantly. Cookie expiry, Meta markup changes, rate limits, challenge pages |
| Recovery | Re-paste `sessionid` / `ds_user_id` / `csrftoken` from a fresh burner login |
| Fallback | None. If it breaks permanently, use Instagram's own "Following" chronological view. |

**Quarantine is deliberate.** Instagram lives in its own category behind a flag so that
when it breaks — and it will — nothing else in the stack is affected. Failure shows as an
empty category, never as an error elsewhere.

### Forums (CSS Selector Bridge)

| | |
| --- | --- |
| Bridge | `CssSelectorBridge` |
| Credentials | None |
| Config | One `FORUM_TARGETS` line per forum (see inputs doc C4) |
| Breaks when | The forum restyles its thread listing |
| Recovery | Re-inspect the selectors and update that one line |
| Detection | A broken selector returns **zero items** — indistinguishable from "no new posts". Verify non-empty at subscribe time. |

Symptoms of a broken selector, in order of likelihood:

1. Feed parses, returns 0 items → selector matched nothing.
2. Feed parses, titles are empty or are raw HTML → title selector too broad or too narrow.
3. Links point to `javascript:;` → link selector hit a wrapper element, not the anchor.
4. Dates are wrong or in the future → date selector matched a relative-time element.

---

## 4. Categories

Create these in FreshRSS, then refine with mute/hide and filters in WS6.

| Category | Contents | Default treatment |
| --- | --- | --- |
| `Tech` | HN, Lemmy, GitHub | Normal |
| `Reading` | Bear Blog, personal blogs | Normal — the long-form core |
| `Forums` | CSS-scraped forums | **Hide** — visit deliberately, not passively |
| `Video` | YouTube | **Mute** — watch when you choose to |
| `Social` | Instagram | **Hide** + flagged |
| `Media` | News-ish, high volume | **Mute** or filter hard |

Mute and hide are the primary tools for breaking the addictive pattern. Mute keeps a feed
out of "All Articles" while still reachable; hide removes it from the stream entirely
unless you click the feed directly.

---

## 5. Extension: Youlag

| | |
| --- | --- |
| Purpose | Video-shaped layout for YouTube feeds; DeArrow-style thumbnails; miniplayer; blocks Shorts |
| Requires | **FreshRSS ≥ 1.30.0** |
| Install | `./scripts/install-youlag.sh` (drops `xExtension-Youlag` into `freshrss-extensions/`), then enable in Settings → Extensions |
| Update | Delete the folder, re-run the script |
| License | GPL-3.0 |

Optional but close to essential if YouTube is a large part of your list — it converts a
wall of thumbnails into something closer to a reading experience.

---

## 6. Onboarding checklist

```
[ ] 1. Native-feed sources first (no bridge, no token, no breakage)
[ ] 2. YouTube channel IDs resolved, feeds added
[ ] 3. Reddit subs added, RSSBRIDGE_USER_AGENT set
[ ] 4. Lemmy communities added
[ ] 5. GitHub — releases.atom for repos, bridge only for org-wide
[ ] 6. Instagram left disabled until everything else works
[ ] 7. Forums: selectors found AND each feed verified non-empty
[ ] 8. Youlag installed if YouTube is significant
[ ] 9. Categories assigned to every feed
[ ] 10. Mute/hide applied to high-volume sources
[ ] 11. Backup taken (scripts/backup.sh) before further changes
```

**Step 11 is not optional.** Subscriptions are the one thing here you cannot regenerate
from a config file.

---

## 7. Verification

After adding a source, confirm it is genuinely working:

```bash
# Does the feed exist and return items?
curl -s "http://127.0.0.1:3000/?action=display&bridge=CssSelectorBridge&...&token=$RSSBRIDGE_TOKEN" \
  | grep -c "<entry>"

# Is FreshRSS actually receiving it? (list the users that exist)
./scripts/services.sh status
```

Then in the web UI: the feed's **last pull** should be recent and **last update** should
show items. A feed that pulls successfully but yields zero items is the failure mode to
watch for — it looks healthy and is not.
