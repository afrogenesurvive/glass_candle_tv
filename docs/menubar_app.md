# Menu Bar Application

`black_glass_candle.app` — a menu bar client for FreshRSS. Swift 6 · SwiftUI + AppKit ·
macOS 15+ · Apple Silicon.

Modelled on the `DS-mon` / `Stats` approach: a single SwiftPM executable target, no Xcode
project, a hand-assembled `.app` bundle, and `LSUIElement=true` so it lives only in the
menu bar.

---

## 1. Why a native app rather than a web shortcut

The goal of this project is to remove the pull of an infinite feed. A browser tab
containing a feed reader is one keystroke from every other tab. A menu bar item that
reports a finite number and opens to exactly those items is the opposite shape: it
answers "is there anything for me" without offering anything to scroll.

---

## 2. Architecture

```mermaid
graph TB
  subgraph Entry
    APP["BlackGlassCandleApp<br/>@main + AppDelegate"]
  end

  subgraph StatusBar["Menu bar"]
    SBC[StatusBarController<br/>NSStatusItem + PopoverWindow]
    SBV[StatusBarView<br/>custom NSView, draws candle]
  end

  subgraph UI["SwiftUI"]
    POP[PopoverView]
    ART[ArticleListView]
    SET[SettingsView]
    WEB[WebViewPane<br/>WKWebView]
  end

  subgraph Model
    CLIENT[FreshRSSClient<br/>@MainActor @Observable]
    DTO[Models<br/>Feed, Article, UnreadSnapshot]
  end

  subgraph Net
    API[FreshRSSAPI<br/>Google Reader API actor]
    BRIDGE[BridgeHealthCheck]
  end

  subgraph Store
    KC[KeychainStore]
    PREFS[PrefsStore]
  end

  subgraph Service
    SCHED[RefreshScheduler]
  end

  APP --> SBC
  APP --> CLIENT
  SBC --> SBV
  SBC --> POP
  POP --> ART
  POP --> WEB
  SBC --> SET
  CLIENT --> API
  CLIENT --> BRIDGE
  API --> KC
  CLIENT --> PREFS
  SCHED --> CLIENT
  CLIENT -.notifies.-> SBC
```

**Data flow:** `RefreshScheduler` ticks → `FreshRSSClient.refresh()` → `FreshRSSAPI`
calls the Google Reader API → the client publishes a new `UnreadSnapshot` → the status
view redraws and the popover updates via `@Observable`.

---

## 3. File map

```
Sources/BlackGlassCandle/
├── BlackGlassCandleApp.swift        @main, AppDelegate, lifecycle
├── StatusBar/
│   ├── StatusBarController.swift    NSStatusItem, PopoverWindow, event wiring
│   ├── StatusBarView.swift          custom NSView — the candle
│   └── CandleIcon.swift             programmatic vector icon (no PNG assets)
├── UI/
│   ├── PopoverView.swift            summary panel
│   ├── ArticleListView.swift        unread article rows
│   ├── SettingsView.swift           connection + display settings
│   └── WebViewPane.swift            embedded FreshRSS web UI
├── Model/
│   ├── Models.swift                 Feed, Article, UnreadSnapshot, FeedCategory
│   └── FreshRSSClient.swift         @MainActor @Observable app state
├── Net/
│   ├── FreshRSSAPI.swift            Google Reader API client (actor)
│   └── BridgeHealthCheck.swift      RSS-Bridge reachability probe
├── Store/
│   ├── KeychainStore.swift          API password in the login keychain
│   └── PrefsStore.swift             UserDefaults-backed settings
└── Service/
    └── RefreshScheduler.swift       timer-driven refresh
```

---

## 4. The menu bar indicator

A small candle glyph plus one vertical **flame** bar. The flame's height and colour track
unread pressure, in the same visual language as `DS-mon`'s LED column.

| State | Flame | Meaning |
| --- | --- | --- |
| Stack unreachable | Grey, stubbed | The services aren't running, or the URL is wrong |
| 0 unread | Dim blue, minimum height | Caught up |
| 1–10 unread | Green | Normal |
| 11–40 unread | Amber | Backlog forming |
| 41+ unread | White-hot, slow blink | You are avoiding something |

Text modes (user-selectable): `unread` count · `unread / total` · `off`.
The icon is drawn with `NSBezierPath` at runtime and marked `isTemplate = true`, so it
inverts automatically for light and dark menu bars and no binary assets are needed.

---

## 5. FreshRSS API contract

All calls go to `MENUBAR_API_BASE_URL` (default
`http://127.0.0.1:8080/api/greader.php`).

| # | Purpose | Request |
| --- | --- | --- |
| 1 | **Authenticate** | `POST /accounts/ClientLogin` — body `Email=…&Passwd=…` → response text contains `Auth=user/token` |
| 2 | **Unread counts** | `GET /reader/api/0/unread-count?output=json` |
| 3 | **Subscriptions** | `GET /reader/api/0/subscription/list?output=json` |
| 4 | **Categories** | `GET /reader/api/0/tag/list?output=json` |
| 5 | **Unread articles** | `GET /reader/api/0/stream/contents/reading-list?xt=user/-/state/com.google/read&n=50&output=json` |
| 6 | **Write token** | `GET /reader/api/0/token` |
| 7 | **Mark read** | `POST /reader/api/0/edit-tag` — `a=user/-/state/com.google/read&i=<id>&T=<token>` |

Requests 2–7 carry `Authorization: GoogleLogin auth=<value from #1>`.

The token from #1 is cached in memory until a call returns `401`, at which point the
client re-authenticates once and retries. The token from #6 is cached separately and
refreshed on the same trigger.

### Unread-count response shape

```json
{
  "max": 1000,
  "unreadcounts": [
    { "id": "user/-/state/com.google/reading-list", "count": 12 },
    { "id": "feed/http://example.com/feed",         "count": 3  },
    { "id": "user/-/label/Tech",                    "count": 5  }
  ]
}
```

The `reading-list` entry is the total. `feed/…` entries are per-feed. `user/-/label/…`
entries are per-category and are what the popover groups by.

---

## 6. States the app must handle

The distinction matters: a menu bar app that shows a spinner forever is worse than one
that says why it is stuck.

| State | Trigger | Display |
| --- | --- | --- |
| `unconfigured` | No API password stored | Candle grey; popover prompts for setup |
| `unreachable` | Connection refused / timeout | Grey stubbed flame; "Stack is down" + Retry button |
| `unauthorized` | `401` after re-auth | Amber flame; "API password rejected" + Settings button |
| `apiDisabled` | `503` from ClientLogin | Amber; "API access is off in FreshRSS" — the concrete fix |
| `ok` | Unread snapshot parsed | Flame reflects pressure |

`apiDisabled` deserves its own state because it is the single most likely failure on a
fresh install, and the raw error is unhelpful.

---

## 7. Settings

| Setting | Storage | Default |
| --- | --- | --- |
| API base URL | `UserDefaults` | `http://127.0.0.1:8080/api/greader.php` |
| API user | `UserDefaults` | `admin` |
| API password | **Keychain** | — |
| Refresh interval | `UserDefaults` | 300 s |
| Menu bar text mode | `UserDefaults` | Unread count |
| Show flame indicator | `UserDefaults` | true |
| Embedded web UI instead of summary | `UserDefaults` | false |
| Launch at login | `SMAppService` | false |

Credentials never enter `UserDefaults`; only `KeychainStore` touches them.

---

## 8. Deltas from the `DS-mon` implementation

`DS-mon` is the template, but four of its choices should not be copied:

| `DS-mon` does | This app does | Why |
| --- | --- | --- |
| `statusItem.setValue(view, forKey: "view")` | `statusItem.button` + `addSubview` | The former pokes an undocumented private ivar via KVC. It works, but it is not API and can break in a point release. |
| AES-GCM key file on disk | macOS Keychain (`kSecClassGenericPassword`) | Removes a key-file lifecycle (permissions, backup, migration, "where did it go"). Same security, less to get wrong. |
| Bundled PNGs declared as `.process()` resources | Runtime `NSBezierPath` drawing | No binary assets in git, nothing to keep in sync between `Package.swift`, `build.sh` and the source tree. |
| `SMLoginItemSetEnabled` | `SMAppService.mainApp.register()` | The former is deprecated on current macOS. |

One thing that **must** be copied verbatim: the `PopoverWindow: NSWindow` subclass
overriding `canBecomeKey` and `canBecomeMain`. A default borderless `NSWindow` cannot
become key, so SwiftUI `TextField`s inside it never receive keystrokes. `DS-mon` has a
comment about exactly this, and the settings form will be unusable without it.

---

## 9. Build and run

```bash
swift build                      # debug
./scripts/build.sh               # release + .app bundle
open build/black_glass_candle.app
```

`scripts/build.sh` derives the version from the current git branch and the build number
from the commit count, matching the `DS-mon` convention.

The app is unsigned. First launch requires **right-click → Open** to clear Gatekeeper.

---

## 10. Caveats

- **The app is a client, not a server.** With the services stopped it shows `unreachable` and
  nothing else works. That is by design; it does not cache articles.
- **Local-only by default.** `127.0.0.1` means it works on this Mac only. Reading from
  another device means the web UI, not this app.
- **One user.** It stores a single set of credentials. Multi-account is out of scope.
- **No offline reading.** FreshRSS is the source of truth, and it runs as a background
  service on this machine. With it stopped, the app shows *stack unreachable* and nothing
  else works.
