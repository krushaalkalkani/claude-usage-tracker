# Claude Usage Tracker v2 — Menu Bar Plan

Status: implemented (this document is the design record; see `README.md` for usage).

---

## 1. Current architecture (v1)

| Piece | What it is | Notes |
|---|---|---|
| `src/App.jsx` | Single ~640-line React component | All state, fetching, parsing, charting, and styling inline |
| `src/components/` | `Gauge`, `StatusDot`, `DetailRow` | Presentational only |
| `src/utils/time.js` | `timeUntil`, `resetLabel` | Fine, reused conceptually in v2 |
| `src/utils/styles.js` | Inline style object `S` | Dark-only glassmorphism |
| `vite.config.js` | Dev proxy `/api` → `api.anthropic.com`, injects `CLAUDE_CODE_OAUTH_TOKEN` | Works |
| `vercel.json` | Same rewrite in production | Works |
| `swiftbar/claude-usage.2m.sh` | Bash + `python3` SwiftBar plugin | Reads `~/.claude-usage-token`, polls every 2 min |

### Current limitations

1. **Menu bar** is a SwiftBar text plugin — no icon, no popover, no notifications, no history, no Claude Code awareness. It shells out `curl` + `python3` every 2 minutes.
2. **Token** is stored as plaintext at `~/.claude-usage-token` (mode 600, but still plaintext on disk) and, in the browser, in `localStorage`.
3. **Parsing is hardcoded** to `five_hour`, `seven_day`, `seven_day_{sonnet,opus,haiku}`. The API now returns a richer, differently-shaped `limits[]` array that the app ignores entirely, so **model-scoped limits never render** (`seven_day_opus`/`seven_day_sonnet` are `null` on this account, while `limits[]` carries a live model-scoped limit).
4. **Currency bug**: `extra_usage.used_credits` is in *minor units* (the payload also carries `decimal_places: 2`). v1 renders `$3303.00 of $3000.00` where the truth is **$33.03 of $30.00** — a 100× overstatement.
5. **No stale-data handling**: any error path leaves the last render in place but the 429 branch silently returns; a hard failure shows a red banner with no "last known good" framing.
6. **Analytics are weak**: burn rate uses the last 6 poll samples with no reset-boundary detection, so a quota reset produces a negative delta that is silently discarded rather than restarting the window.
7. **`useEffect` polling** decrements a 1 Hz timer purely to drive a 120 s fetch — 120 renders per fetch.
8. **No notifications, no settings, no privacy documentation.**

---

## 2. API field inventory

Probed live on this machine against the personal OAuth endpoints with a redacting script
(`scratchpad/probe_usage.py`; the token is never printed). Values below are from a
`claude_max` / `default_claude_max_5x` account.

### `GET https://api.anthropic.com/api/oauth/usage`

Headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`.

| Field | Type | Example | Description | Supported | Shown in v1 | Shown in v2 |
|---|---|---|---|---|---|---|
| `five_hour.utilization` | float | `18.0` | Session window % used | yes | yes | yes (via `limits[]` when present) |
| `five_hour.resets_at` | ISO8601 | `2026-08-08T20:00:00.196578+00:00` | Session reset instant | yes | yes | yes |
| `five_hour.limit_dollars` | null | `null` | Not populated on this plan | yes (null) | no | yes if non-null |
| `five_hour.used_dollars` | null | `null` | ” | yes (null) | no | yes if non-null |
| `five_hour.remaining_dollars` | null | `null` | ” | yes (null) | no | yes if non-null |
| `seven_day.*` | same shape | `32.0` | Weekly all-model window | yes | yes | yes |
| `seven_day_opus` | object\|null | `null` | Legacy per-model window | yes (null here) | yes | yes if non-null |
| `seven_day_sonnet` | object\|null | `null` | ” | yes (null here) | yes | yes if non-null |
| `seven_day_cowork` | object\|null | `null` | Surface-scoped window | yes (null here) | no | yes if non-null |
| `seven_day_oauth_apps` | object\|null | `null` | ” | yes (null here) | no | yes if non-null |
| `seven_day_omelette`, `tangelo`, `iguana_necktie`, `omelette_promotional`, `cinder_cove`, `amber_ladder`, `nimbus_quill` | object\|null | mostly `null`; `nimbus_quill.utilization = 0.0` | **Internal codename buckets.** Undocumented, unstable | yes | no | only via `limits[]`; never guessed |
| **`limits[]`** | array | 3 entries | **The modern shape — the one v2 builds on** | yes | **no** | **yes** |
| `limits[].kind` | string | `session`, `weekly_all`, `weekly_scoped` | Limit identity | yes | no | yes |
| `limits[].group` | string | `session`, `weekly` | Grouping for display | yes | no | yes |
| `limits[].percent` | int | `18`, `32`, `45` | % used | yes | no | yes |
| `limits[].severity` | string | `normal` (also `critical` seen on `spend`) | Server-side severity | yes | no | yes (server value wins over local thresholds) |
| `limits[].resets_at` | ISO8601 | `2026-08-13T20:00:00…` | Reset instant | yes | no | yes |
| `limits[].is_active` | bool | `true` on the model-scoped weekly | Limit currently in force for the session | yes | no | yes (badge + primary-metric hint) |
| `limits[].scope` | object\|null | `{"model":{"display_name":"Fable","id":null},"surface":null}` | **How model-specific limits are actually exposed** | yes | no | yes |
| `limits[].scope.model.display_name` | string | `Fable` | Model label | yes | no | yes |
| `limits[].scope.model.id` | string\|null | `null` | Model id | yes (null) | no | yes if non-null |
| `limits[].scope.surface` | string\|null | `null` | Surface label (e.g. Cowork) | yes (null) | no | yes if non-null |
| `extra_usage.is_enabled` | bool | `false` | Extra usage currently on | yes | yes | yes |
| `extra_usage.monthly_limit` | int | `3000` | **Minor units** → $30.00 | yes | yes (**bug: ×100**) | yes (fixed) |
| `extra_usage.used_credits` | float | `3303.0` | **Minor units** → $33.03 | yes | yes (**bug: ×100**) | yes (fixed) |
| `extra_usage.utilization` | float | `100.0` | % of monthly cap | yes | no | yes |
| `extra_usage.currency` | string | `USD` | ISO currency | yes | no | yes |
| `extra_usage.decimal_places` | int | `2` | Minor-unit exponent | yes | **ignored** | yes |
| `extra_usage.disabled_reason` | string | `org_level_disabled_until` | Why it is off | yes | no | yes |
| `extra_usage.user_disabled` | bool | `false` | User turned it off | yes | no | yes |
| `extra_usage.spend_limit_reached` | bool | `true` | Cap hit | yes | no | yes |
| `extra_usage.credits_ever_enabled` | bool | `true` | Ever used | yes | no | yes |
| `extra_usage.daily` / `.weekly` | null | `null` | Sub-period caps | yes (null) | no | yes if non-null |
| **`spend`** | object | — | **Modern money shape; preferred over `extra_usage`** | yes | no | yes |
| `spend.used.amount_minor` | int | `3303` | $33.03 | yes | no | yes |
| `spend.used.currency` | string | `USD` | — | yes | no | yes |
| `spend.used.exponent` | int | `2` | Minor-unit exponent | yes | no | yes |
| `spend.limit.{amount_minor,currency,exponent}` | object | `3000/USD/2` | $30.00 cap | yes | no | yes |
| `spend.percent` | int | `100` | % of cap | yes | no | yes |
| `spend.severity` | string | `critical` | Server severity | yes | no | yes |
| `spend.enabled` | bool | `false` | Spend enabled | yes | no | yes |
| `spend.disabled_reason` | string | `org_level_disabled_until` | — | yes | no | yes |
| `spend.cap.money` | object\|null | `null` | Money cap | yes (null) | no | yes if non-null |
| `spend.cap.credits.{amount_minor,exponent}` | object | `3000/2` | Credit cap | yes | no | yes |
| `spend.balance` | null | `null` | Prepaid balance | yes (null) | no | yes if non-null |
| `spend.auto_reload` | null | `null` | Auto top-up config | yes (null) | no | yes if non-null |
| `spend.disclaimer` | string | 113 chars | Legal text | yes | no | yes (tooltip) |
| `spend.can_purchase_credits` | bool | `false` | — | yes | no | no (no purchase UI) |
| `spend.can_toggle` | bool | `false` | — | yes | no | no |
| `member_dashboard_available` | bool | `false` | Org dashboard link availability | yes | no | no |

Response headers also carry `anthropic-organization-id` and `anthropic-workspace-id` (treated as sensitive; never logged).

### `resets_at` is not byte-stable — treat it as a whole-second value

The same quota window returns a **different `resets_at` on every request**, varying in the
fractional seconds:

```
poll 1   "2026-08-13T20:00:00.196578+00:00"
poll 2   "2026-08-13T20:00:00.275325+00:00"
```

The whole-second instant is stable; the sub-second part is response noise. This is not a
curiosity — it caused a live bug. The ledger persists dates at whole-second precision, so a
stored boundary read back as `…:00.000` while the next live value was `…:00.275`. Reset
detection compared the two, concluded the window had rolled, and fired
*"Weekly quota reset — was 39%, now 39%"* **every polling interval**, re-arming every usage
threshold behind it.

Two rules follow, both now enforced:

1. **Truncate `resets_at` to the second at the parse boundary** (`Date.truncatingSubsecond`), so
   the jitter never reaches comparison logic, dedup keys, or disk.
2. **Never treat a timestamp as evidence of a reset.** A quota window has rolled over only when
   utilisation actually *falls*; a moved boundary is corroboration at most. That rule holds even
   if the API changes this behaviour again.

Notification dedup keys additionally bucket the boundary to the minute, so no future precision
change can silently break deduplication.

### `GET https://api.anthropic.com/api/oauth/profile`

Fetched at most once per hour; supplies plan metadata the usage endpoint does not.

| Field | Type | Example | Used |
|---|---|---|---|
| `account.display_name` | string | `Krushal` | yes |
| `account.email` | string | redacted | **no** (never displayed or stored) |
| `account.uuid` | string | redacted | no |
| `account.has_claude_max` / `has_claude_pro` | bool | `true` / `false` | yes (plan label) |
| `organization.organization_type` | string | `claude_max` | yes |
| `organization.rate_limit_tier` | string | `default_claude_max_5x` | yes |
| `organization.subscription_status` | string | `active` | yes |
| `organization.has_extra_usage_enabled` | bool | `true` | yes |
| `organization.billing_type` | string | `stripe_subscription` | no |
| `organization.name`, `.uuid` | string | contains email | **no** |
| `application.{name,slug}` | string | `Claude Code` / `claude-code` | no |

### Model-specific limits: the honest answer

Anthropic **does** expose model-specific limits, but **not** through the `seven_day_opus` /
`seven_day_sonnet` keys v1 reads (both `null` here). They arrive as
`limits[]` entries with `kind: "weekly_scoped"` and a populated `scope.model.display_name`.
v2 renders the **Model limits** section from those entries only, and hides the section
entirely when no scoped entry exists. Legacy `seven_day_<model>` keys are still read as a
fallback so older/other accounts keep working.

### Codename keys

`tangelo`, `iguana_necktie`, `nimbus_quill`, `omelette_promotional`, `cinder_cove`,
`amber_ladder`, `seven_day_omelette` are internal names with no documented meaning. v2
**never invents labels for them**. They are preserved in the raw payload for debug mode and
surfaced only if they ever appear inside `limits[]` with a real `kind`/`scope`.

---

## 3. Proposed architecture

```
claude-usage-tracker/
├── src/                      React dashboard (kept, upgraded)
│   └── lib/usageModel.js     ← NEW: shared normalizer (JS port of the Swift one)
├── macos/                    ← NEW: native SwiftUI menu bar app (SwiftPM, no Xcode needed)
│   ├── Package.swift
│   ├── hooks/claude-activity-hook          observability-only Claude Code hook
│   ├── scripts/build-app.sh                → ClaudeUsage.app
│   ├── scripts/install-hooks.sh            idempotent settings.json patcher
│   ├── scripts/uninstall-hooks.sh
│   └── ClaudeUsage/
│       ├── App/            @main, MenuBarExtra, app model (UI layer)
│       ├── Views/          popover panel, settings, sparkline, icon renderer
│       ├── Models/         UsageSnapshot, LimitWindow, SpendInfo, ActivityState, JSONValue
│       ├── Services/       API client, TokenStore, HistoryStore, ActivityMonitor, Settings
│       ├── Analytics/      burn rate / projection / ETA (pure)
│       ├── Notifications/  policy (pure) + UNUserNotificationCenter delivery
│       ├── Resources/      Info.plist
│       └── Tests/          swift-testing suites + sanitized fixtures
└── docs/MENUBAR_V2_PLAN.md
```

**Why SwiftPM and not an Xcode project:** this machine has Command Line Tools only —
`xcodebuild` is unavailable. `swift build` + a bundling script produces a real
`ClaudeUsage.app` with SwiftUI, AppKit, UserNotifications and ServiceManagement all linking
correctly, and `swift test` runs the `Testing` framework. Anyone with Xcode can still open
`macos/Package.swift` directly.

**Layering.** `ClaudeUsageCore` is a plain library with no SwiftUI import: models, parsing,
analytics, notification policy, activity aggregation. It is 100 % unit-testable and holds
every decision that could be wrong. `ClaudeUsageApp` is the executable: SwiftUI views plus
the small amount of AppKit needed for the menu-bar icon and login item.

---

## 4. Menu bar design

- Icon is drawn programmatically into an `NSImage` with `isTemplate = true`, so AppKit tints
  it for light and dark menu bars automatically. Drawing happens inside
  `NSImage(size:flipped:drawingHandler:)`, which re-renders per backing scale — Retina-crisp
  with no bitmap assets.
- The glyph is a 16 pt ring: a full track at 30 % alpha plus a filled arc for the current
  percentage, starting at 12 o'clock. Alpha differences survive template tinting, so the fill
  level reads at menu-bar size without color.
- Colour is used **only** at warning/critical, and only when the user leaves
  "Tint icon on warning" on. In those states the image is emitted non-template with a system
  orange/red tint.
- Display modes: **icon only**, **percentage only**, **icon + percentage** (default).
- The percentage shown is the **primary metric**: by default `auto`, which picks the limit
  with the highest utilisation, preferring an `is_active` limit when percentages tie within
  1 point. The user can pin it to session / weekly / highest-model instead.
- When the primary metric is *not* the session limit — the "5h = 25 %, 7d = 91 %" case — the
  menu bar appends a one-character source tag (`W` weekly, `M` model, `$` spend) after the
  number and the popover header states which limit is the bottleneck. That is the intelligent
  indication the brief asks for, without alarming color.

## 5. Popover design

380 pt wide, hand-laid stack on a strict 4 pt rhythm.

**The thesis.** Every usage tracker shows *67% used*, *resets in 1h 4m*, and *burning 44%/h* as
three separate facts and leaves you to combine them. The only question a person actually has is
**"will I run out before it resets?"** The panel is built to answer that.

**The runway** is the signature element. Its scale runs from *now* to *the reset*; lit ticks are
how far the current burn rate carries you; the raised tick is the moment you go dry; the dim
tail is time you will spend blocked. With too little history it renders an unlit scale and says
"no trend yet" rather than drawing a line it cannot support.

**One hero, everything else quiet.** The limit closest to its ceiling gets a raised card; the
rest are two-line rows with values in a strict right-hand column. That is what makes the
"5 h = 25 %, 7 d = 91 %" case read correctly — weekly takes the hero and session demotes itself.

```
● Claude Usage                            Max · 12s ago
┌──────────────────────────────────────────────┐
│ SESSION · 5-HOUR                    TIGHTEST │
│ 12% remaining                      1h 4m left│
│     88% used                                 │
│ ▮▮▮▮▮▮▮▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯                │
│ now  dry in 16m · blocked 47m         8:26 PM│
└──────────────────────────────────────────────┘
────────────────────────────────────────────────
OTHER LIMITS
Weekly                    ▮▮▮▮▮▯▯▯▯▯▯▯    36%
5d 1h left
Fable      ACTIVE         ▮▮▮▮▮▮▯▯▯▯▯▯    51%
5d 1h left
────────────────────────────────────────────────
EXTRA USAGE                         cap reached
$33.03 of $30.00                  over by $3.03
────────────────────────────────────────────────
CLAUDE CODE                  2 sessions · 2 agents
⚡ finance-app   running tool · Bash            3m
🔓 claude-usage-tracker  Permission requested  40s
────────────────────────────────────────────────
TREND                        1h  [5h]  24h  7d
  ╱‾‾╲___╱‾‾
────────────────────────────────────────────────
↻  ▤  ⚙                                       ⏻
```

**Visual language.** Monochrome base with a single accent. An earlier pass tinted the whole
panel with the severity colour and it made a perfectly healthy account look like a pastel
warning — colour that is always on stops meaning anything. Severity now appears only in a 5 pt
status dot, the hero figure, and the meters. Depth is real (scrim, inner stroke, shadow) rather
than a 6 % fill that reads as unfinished. SF Pro Display with −1.8 tracking for the figure —
Rounded reads friendly where this should read precise — and SF Mono for every value that
changes in place. Discrete tick meters instead of capsule bars: countable at a glance, and able
to carry the runway's breakpoint, which a solid bar cannot.

Sections whose data the API did not return are **not rendered** — no placeholders, no
zeros, no invented numbers.

Screenshots are generated, not captured: `ClaudeUsage --render-preview <dir>` renders every
scenario in both appearances from fixtures, so `docs/screenshots/` cannot drift from the UI.

## 6. Claude Code activity tracking

**Transport.** A single executable hook script, `macos/hooks/claude-activity-hook`, registered
for every observability-relevant event. Every registration uses `"async": true` so the hook is
fire-and-forget and **cannot delay or block Claude Code**. It always exits 0 and prints
nothing on stdout, so it can never influence a turn.

**Storage.** `~/.claude-usage-tracker/`
```
sessions/<session_id>.json    one file per Claude Code session, written atomically
events.jsonl                  ring buffer, last 200 event *names* + timestamps
```
Each hook invocation touches **only its own session file**, so concurrent sessions never
contend for a lock. The app aggregates by reading the directory. `activity.json` is written as
a convenience rollup for third-party consumers but is not the app's source of
truth.

**Session record** (metadata only):
```json
{
  "schema": 1, "sessionId": "…", "project": "claude-usage-tracker",
  "cwd": "/Users/…/claude-usage-tracker", "model": null,
  "status": "working", "statusDetail": "Bash",
  "activeAgents": 2, "openTasks": 0,
  "lastEvent": "PreToolUse", "lastEventAt": "2026-08-08T13:40:02Z",
  "startedAt": "…", "turnStartedAt": "…", "lastCompletedAt": "…",
  "lastTurnSeconds": 84.2, "needsAttention": false, "attentionReason": null,
  "permissionMode": "default", "effort": "high",
  "lastError": null, "claudePid": 41233, "updatedAt": "…"
}
```

**Privacy.** Prompt text (`user_input`), assistant text (`last_assistant_message`), tool
inputs and tool outputs are **never read or written**. The hook copies only: session id, cwd,
event name, tool *name*, permission mode, effort level, agent type, and counters. There is no
opt-in to record content — the code to do so does not exist.

**Event → status mapping**

| Event | Effect |
|---|---|
| `SessionStart` | create record, `idle`, capture `source`, optional `model` |
| `UserPromptSubmit` | `working`, `turnStartedAt = now`, clear attention |
| `PreToolUse` | `runningTool`, `statusDetail = tool_name` |
| `PostToolUse` | back to `working` |
| `PostToolUseFailure` | `working`, `lastError = tool_name` |
| `PermissionRequest` | `permissionRequired`, `needsAttention = true` |
| `Notification` (`permission_prompt`) | `permissionRequired`, attention |
| `Notification` (`idle_prompt`) | `waitingForUser`, attention |
| `SubagentStart` / `SubagentStop` | `activeAgents ±1`; `runningAgents` while > 0 |
| `TaskCreated` / `TaskCompleted` | `openTasks ±1` |
| `TeammateIdle` | `waitingForUser`, attention |
| `Stop` | `completed` → decays to `idle`; record `lastTurnSeconds` |
| `StopFailure` matcher `rate_limit` | `rateLimited`, attention |
| `StopFailure` (other) | `error`, attention |
| `PreCompact` / `PostCompact` | `compacting` / back to `working` |
| `SessionEnd` | delete the session file |

**Liveness — the honest limitation.** Hooks are spawned in exec form (`command` + `args`), so
the hook process's parent *is* the Claude Code process; the hook records `getppid()` as
`claudePid`. The app then treats a session as dead when `kill(pid, 0)` fails, and as *stale*
when `updatedAt` is older than 10 minutes while the status claims activity. Neither signal is
perfect: a `SIGKILL`ed Claude Code leaves a file behind until the pid check reaps it, and pid
reuse is theoretically possible. Sessions started **before** the hooks were installed are
invisible. All three limitations are stated in the README rather than papered over.

## 7. Notification architecture

`NotificationPolicy` is a pure function:

```swift
func evaluate(context: PolicyContext, ledger: inout NotificationLedger) -> [PendingNotification]
```

- **Threshold alerts** at configurable percentages (default 50/75/90/95/100), evaluated per
  limit. The dedup key is `limitId + resets_at + threshold`, so a new quota window
  automatically re-arms every threshold and nothing fires twice inside one window.
- **Reset notices** fire when a limit's `resets_at` moves forward *and* the pre-reset
  percentage was above a floor (default 25 %), so an idle week stays quiet.
- **Projection alert** ("projected to hit 100 % before reset") requires ≥ 4 samples spanning
  ≥ 10 minutes and a positive rate; otherwise the popover shows "Not enough data" and no
  notification is sent.
- **Surge alert** when the rate over the last two samples exceeds 3× the window average and
  the limit is above 40 %.
- **API state alerts**: auth expired, unavailable (only after 3 consecutive failures), rate
  limited.
- **Claude Code alerts**: permission required, waiting for input, long task completed
  (only when the turn ran ≥ the configured minimum, default 60 s), turn error, rate limited,
  subagent team finished.
- Every category has an independent **cooldown** (default 15 min; 2 min for attention alerts)
  and obeys **quiet hours**. Quiet hours suppress rather than queue, except for `critical`
  severity if the user enables "always allow critical".

Delivery is `UNUserNotificationCenter`. If authorization is denied or unavailable (unsigned
build), the service degrades to `osascript -e 'display notification'` and Settings shows the
current authorization state instead of failing silently.

## 8. Data storage

Everything is local, under `~/.claude-usage-tracker/`:

| Path | Contents | Retention |
|---|---|---|
| `history.json` | `[{t, limits:{id:percent}, spend}]` samples | 24 h / 7 d / 30 d (default 7 d), pruned on write |
| `sessions/*.json` | Claude Code session metadata | deleted on `SessionEnd`, reaped when the pid dies |
| `events.jsonl` | last 200 event names + timestamps | ring buffer |
| `activity.json` | rollup for other consumers | overwritten |
| `notifications.json` | dedup ledger + cooldown timestamps | pruned to live windows |
| `last-usage.json` | last successful payload for cold-start display | overwritten |

Settings live in `UserDefaults` (`com.krushal.claude-usage-tracker`). No network destination
other than `api.anthropic.com`. No telemetry, no analytics, no crash reporting.

## 9. Security

- **Keychain first.** The app stores a user-pasted token in the login keychain
  (`kSecClassGenericPassword`, service `com.krushal.claude-usage-tracker`,
  `kSecAttrAccessibleWhenUnlocked`).
- **Claude Code credential reuse.** If no app token exists, the app reads
  `Claude Code-credentials` from the keychain and uses `claudeAiOauth.accessToken`
  (honouring `expiresAt` when non-zero — it is `0`/unset on this machine, which is treated as
  "unknown", not "expired"). macOS prompts for keychain access on first read; this is the
  documented, user-visible consent point. The token is never copied out of the keychain onto
  disk.
- **Legacy file** `~/.claude-usage-token` is still read last, for v1 compatibility.
- The token is held in memory as a `String` used only to build an `Authorization` header. It
  is never logged, never written to history, never included in debug exports. Debug mode
  dumps the *response* JSON only, with `Authorization` scrubbed and
  `anthropic-organization-id` / `anthropic-workspace-id` redacted.
- `URLSession` is configured with `.ephemeral` and no HTTP cache so the response never lands
  on disk.

## 10. Error states

| Condition | Behaviour |
|---|---|
| 401 / token expired | Amber banner "Authentication expired — reconnect", last-known data stays visible and is labelled stale; one notification, then silence |
| 403 | "Access denied for this token" |
| 429 | Respect `Retry-After`; banner "Rate limited — retrying in Ns"; **no** data reset |
| 5xx / network / timeout | Exponential backoff 30 s → 60 s → 120 s → 300 s (capped) with ±20 % jitter; banner appears only after the 2nd consecutive failure |
| Invalid JSON / schema change | Data kept, banner "Usage format not recognised"; raw body retained for debug mode; **never a crash** |
| No limits parsed | "No usage data reported" — not `0 %` |
| Partial data | Render the sections that parsed; omit the rest |

Last-known-good is persisted so a cold launch shows real numbers with an explicit
"Updated N min ago" instead of zeros.

## 11. API compatibility strategy

1. The payload is first decoded into a `JSONValue` tree (a total, never-throwing
   representation), then *read* with optional accessors. A removed field yields `nil`; an
   added field is preserved untouched.
2. `limits[]` is the primary source. Legacy top-level keys are a fallback, merged only for
   ids that `limits[]` did not already provide.
3. Unknown `kind` values still render, using the raw string as the title, so a new limit type
   appears rather than disappearing.
4. Money is read through a `Money` type that respects `exponent` / `decimal_places`, with a
   safe default of 2 — never a bare division by 100.
5. `schemaWarnings` accumulates a human-readable note whenever an expected field is missing,
   visible in debug mode; it never blocks rendering.

## 12. Implementation phases

1. Core models + parsing + fixtures + tests ✔
2. Services: API client, token store, history, settings ✔
3. Analytics ✔
4. Activity hook + monitor ✔
5. Notification policy + delivery ✔
6. SwiftUI menu bar + popover + settings ✔
7. Bundling script ✔
8. React dashboard upgrade to the shared model ✔
9. ~~SwiftBar refresh~~ — plugin retired once the native app proved out ✔
10. Self-review, fixes, README ✔
