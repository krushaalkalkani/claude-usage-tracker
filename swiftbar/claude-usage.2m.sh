#!/bin/bash
#
# Claude Usage Tracker — SwiftBar fallback plugin.
#
# The native app in macos/ is the full experience (popover, notifications, history, Claude
# Code activity). This plugin stays in the repo as a dependency-free fallback: bash + python3,
# nothing to build, nothing to install.
#
# v2 changes: reads the modern `limits[]` array so model-scoped limits show up, shows the
# tightest limit rather than assuming the session is the constraint, fixes the extra-usage
# currency scaling, and reads Claude Code activity when the hook is installed.
#
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

TOKEN_FILE="$HOME/.claude-usage-token"
ACTIVITY_FILE="$HOME/.claude-usage-tracker/activity.json"
DASHBOARD="https://claude-usage-tracker-xi.vercel.app"

# Prefer the file, fall back to Claude Code's own credentials in the keychain.
TOKEN=""
if [ -f "$TOKEN_FILE" ]; then
  TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
fi
if [ -z "$TOKEN" ]; then
  TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('claudeAiOauth',{}).get('accessToken',''))" 2>/dev/null)
fi

if [ -z "$TOKEN" ]; then
  echo "◌ | size=12"
  echo "---"
  echo "No credentials found | color=#ef4444 size=13"
  echo "Save a token to ~/.claude-usage-token | color=#888 size=11"
  echo "or sign in to Claude Code | color=#888 size=11"
  exit 0
fi

# CLAUDE_USAGE_FIXTURE lets you exercise the rendering path from a saved response without
# spending an API call. Used by scripts/test-swiftbar.sh.
if [ -n "${CLAUDE_USAGE_FIXTURE:-}" ] && [ -f "$CLAUDE_USAGE_FIXTURE" ]; then
  RESPONSE=$(cat "$CLAUDE_USAGE_FIXTURE")
  HTTP_CODE=200
else
  RAW=$(curl -s --max-time 10 -w '\n%{http_code}' \
    "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" 2>/dev/null)
  CURL_STATUS=$?
  HTTP_CODE=$(printf '%s' "$RAW" | tail -1)
  RESPONSE=$(printf '%s' "$RAW" | sed '$d')

  if [ $CURL_STATUS -ne 0 ] || [ -z "$RESPONSE" ]; then
    echo "◌ | size=12"
    echo "---"
    echo "Usage data unavailable | color=#f59e0b size=12"
    echo "Network error or timeout | color=#888 size=11"
    echo "---"
    echo "Retry | refresh=true size=12"
    exit 0
  fi
fi

# Status-specific messages, so a transient 429 does not read as an expired token.
case "$HTTP_CODE" in
  200) ;;
  401|403)
    echo "◌ | size=12"; echo "---"
    echo "Authentication failed | color=#ef4444 size=12"
    echo "Token expired or not permitted | color=#888 size=11"
    echo "---"; echo "Retry | refresh=true size=12"; exit 0 ;;
  429)
    echo "◌ | size=12"; echo "---"
    echo "Rate limited | color=#f59e0b size=12"
    echo "Backing off — retrying next cycle | color=#888 size=11"
    echo "---"; echo "Retry | refresh=true size=12"; exit 0 ;;
  5*)
    echo "◌ | size=12"; echo "---"
    echo "Anthropic is having trouble | color=#f59e0b size=12"
    echo "HTTP $HTTP_CODE | color=#888 size=11"
    echo "---"; echo "Retry | refresh=true size=12"; exit 0 ;;
  *)
    echo "◌ | size=12"; echo "---"
    echo "Unexpected response | color=#f59e0b size=12"
    echo "HTTP $HTTP_CODE | color=#888 size=11"
    echo "---"; echo "Retry | refresh=true size=12"; exit 0 ;;
esac

# All parsing happens in one python3 pass that emits ready-to-print SwiftBar lines. Keeping
# it in a single process matters: SwiftBar runs this every 2 minutes, all day.
# The response travels in the environment, not on stdin — the heredoc below already owns
# stdin, so `sys.stdin.read()` there would read the script itself.
OUTPUT=$(ACTIVITY_FILE="$ACTIVITY_FILE" RESPONSE="$RESPONSE" python3 <<'PY' 2>/dev/null
import json, os, sys
from datetime import datetime, timezone

raw = os.environ.get("RESPONSE", "")
try:
    d = json.loads(raw)
except Exception:
    print("PARSE_ERROR")
    sys.exit(0)

if not isinstance(d, dict) or d.get("error"):
    msg = ""
    if isinstance(d, dict):
        msg = (d.get("error") or {}).get("message", "") if isinstance(d.get("error"), dict) else str(d.get("error"))
    print("API_ERROR")
    print(msg[:80])
    sys.exit(0)


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None


def time_left(value):
    dt = parse_ts(value)
    if not dt:
        return "—"
    secs = int((dt - datetime.now(timezone.utc)).total_seconds())
    if secs <= 0:
        return "now"
    h, m = secs // 3600, (secs % 3600) // 60
    if h >= 24:
        return "%dd %dh" % (h // 24, h % 24)
    if h > 0:
        return "%dh %dm" % (h, m)
    return "%dm" % m


LEGACY = [
    ("five_hour", "session", "Session (5h)"),
    ("seven_day", "weekly_all", "Weekly (7d)"),
    ("seven_day_opus", "weekly_scoped|m:opus", "Opus (7d)"),
    ("seven_day_sonnet", "weekly_scoped|m:sonnet", "Sonnet (7d)"),
    ("seven_day_haiku", "weekly_scoped|m:haiku", "Haiku (7d)"),
]

limits = []
seen = set()

# The modern shape wins; it is the only place model-scoped limits appear.
for entry in (d.get("limits") or []):
    if not isinstance(entry, dict):
        continue
    pct = entry.get("percent", entry.get("utilization"))
    try:
        pct = float(pct)
    except (TypeError, ValueError):
        continue
    kind = entry.get("kind") or "unknown"
    scope = entry.get("scope") or {}
    model = (scope.get("model") or {}).get("display_name")
    surface = scope.get("surface")
    key = "|".join(filter(None, [kind, "m:" + model.lower() if model else None,
                                 "s:" + str(surface).lower() if surface else None]))
    if key in seen:
        continue
    seen.add(key)
    if model:
        label = "%s (7d)" % model
    elif surface:
        label = "%s (7d)" % surface
    elif kind == "session":
        label = "Session (5h)"
    elif kind.startswith("weekly"):
        label = "Weekly (7d)"
    else:
        label = kind.replace("_", " ").title()
    limits.append({
        "label": label, "pct": pct, "resets": entry.get("resets_at"),
        "active": bool(entry.get("is_active")), "session": kind == "session",
    })

# Legacy keys fill gaps only.
for raw_key, ident, label in LEGACY:
    node = d.get(raw_key)
    if not isinstance(node, dict) or ident in seen:
        continue
    try:
        pct = float(node.get("utilization"))
    except (TypeError, ValueError):
        continue
    seen.add(ident)
    limits.append({"label": label, "pct": pct, "resets": node.get("resets_at"),
                   "active": False, "session": raw_key == "five_hour"})

if not limits:
    print("NO_DATA")
    sys.exit(0)

# Session first, then everything else by utilisation.
limits.sort(key=lambda x: (0 if x["session"] else 1, -x["pct"]))

# The menu bar shows the limit closest to its ceiling, tagged when it is not the session.
tightest = max(limits, key=lambda x: (x["pct"], x["active"]))
tag = "" if tightest["session"] else ("M" if "(7d)" in tightest["label"] and not tightest["label"].startswith("Weekly") else "W")

pct = int(round(tightest["pct"]))
if pct >= 90:
    color, status = "#ef4444", "Critical"
elif pct >= 75:
    color, status = "#f59e0b", "Tight"
else:
    color, status = "#10b981", "Good"

print("MENU|%d%s" % (pct, tag))
print("STATUS|%s|%s" % (status, color))
print("HEADLINE|%s is your tightest limit" % tightest["label"])

for item in limits:
    p = int(round(item["pct"]))
    filled = max(0, min(20, p // 5))
    bar = "▓" * filled + "░" * (20 - filled)
    if p >= 90:
        c = "#ef4444"
    elif p >= 75:
        c = "#f59e0b"
    elif item["session"]:
        c = "#10b981"
    else:
        c = "#8b5cf6"
    print("LIMIT|%s|%s|%d|%s|%s|%s" % (
        item["label"], bar, p, c, time_left(item["resets"]),
        "  ·  active" if item["active"] else ""))

# Spend. Amounts are minor units scaled by the exponent the API sends — never a bare /100.
spend = d.get("spend") if isinstance(d.get("spend"), dict) else None
extra = d.get("extra_usage") if isinstance(d.get("extra_usage"), dict) else None


def money(node):
    if not isinstance(node, dict):
        return None
    try:
        minor = int(node["amount_minor"])
    except (KeyError, TypeError, ValueError):
        return None
    exp = int(node.get("exponent", 2))
    return "$%.*f" % (exp, minor / (10 ** exp))


used = money((spend or {}).get("used"))
cap = money((spend or {}).get("limit"))
if (used is None or cap is None) and extra:
    exp = int(extra.get("decimal_places", 2))
    if used is None and extra.get("used_credits") is not None:
        used = "$%.*f" % (exp, float(extra["used_credits"]) / (10 ** exp))
    if cap is None and extra.get("monthly_limit") is not None:
        cap = "$%.*f" % (exp, float(extra["monthly_limit"]) / (10 ** exp))

if used:
    enabled = (spend or {}).get("enabled", (extra or {}).get("is_enabled", False))
    note = "enabled" if enabled else "disabled"
    if (extra or {}).get("spend_limit_reached"):
        note = "cap reached"
    print("SPEND|%s of %s  ·  %s" % (used, cap or "—", note))

# Claude Code activity, when the hook has written a rollup.
try:
    with open(os.environ["ACTIVITY_FILE"]) as fh:
        act = json.load(fh)
    if act.get("sessionCount"):
        bits = ["%d session%s" % (act["sessionCount"], "" if act["sessionCount"] == 1 else "s")]
        if act.get("activeCount"):
            bits.append("%d active" % act["activeCount"])
        if act.get("activeAgents"):
            bits.append("%d agents" % act["activeAgents"])
        label = (act.get("status") or "idle").replace("_", " ").title()
        if act.get("project"):
            label += " · %s" % act["project"]
        print("ACTIVITY|%s|%s|%s" % (
            label, "  ·  ".join(bits), "#f59e0b" if act.get("needsAttention") else "#888"))
except Exception:
    pass
PY
)

FIRST=$(echo "$OUTPUT" | head -1)

case "$FIRST" in
  PARSE_ERROR|NO_DATA|"")
    echo "◌ | size=12"
    echo "---"
    echo "Usage format not recognized | color=#f59e0b size=12"
    echo "The API may have changed shape | color=#888 size=11"
    echo "---"
    echo "Retry | refresh=true size=12"
    exit 0
    ;;
  API_ERROR)
    DETAIL=$(echo "$OUTPUT" | sed -n '2p')
    echo "◌ | size=12"
    echo "---"
    echo "API error | color=#ef4444 size=12"
    [ -n "$DETAIL" ] && echo "${DETAIL} | color=#888 size=11"
    echo "Token may be expired | color=#888 size=11"
    echo "---"
    echo "Retry | refresh=true size=12"
    exit 0
    ;;
esac

# ── Menu bar ──
echo "$OUTPUT" | awk -F'|' '/^MENU\|/ { printf "%s | size=11 font=HelveticaNeue-Medium\n", $2 }'

# ── Dropdown ──
echo "---"
echo "$OUTPUT" | awk -F'|' '
  /^STATUS\|/   { printf "Claude Usage | size=14\n%s | size=11 color=%s\n---\n", $2, $3 }
  /^HEADLINE\|/ { printf "%s | size=11 color=#888\n---\n", $2 }
  /^LIMIT\|/    { printf "%s%s | size=11 color=#999\n%s  %d%% | size=11 font=Menlo color=%s\nResets in %s | size=10 color=#555\n---\n", $2, $7, $3, $4, $5, $6 }
  /^SPEND\|/    { printf "Extra usage | size=11 color=#999\n%s | size=11 color=#aaa\n---\n", $2 }
  /^ACTIVITY\|/ { printf "Claude Code | size=11 color=#999\n%s | size=11 color=%s\n%s | size=10 color=#555\n---\n", $2, $4, $3 }
'

echo "Open Dashboard | href=$DASHBOARD size=12"
echo "Refresh | refresh=true size=12"
echo "---"
echo "Updated $(date '+%I:%M %p') | size=10 color=#444"
echo "Native app: macos/scripts/build-app.sh | size=10 color=#444"
