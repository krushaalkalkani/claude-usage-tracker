#!/bin/bash

# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

TOKEN_FILE="$HOME/.claude-usage-token"

if [ ! -f "$TOKEN_FILE" ]; then
  echo "C | size=12"
  echo "---"
  echo "Token not found | color=#ef4444 size=13"
  echo "Save token to ~/.claude-usage-token | color=#888 size=12"
  exit 0
fi

TOKEN=$(cat "$TOKEN_FILE")

RESPONSE=$(curl -s --max-time 10 \
  "https://api.anthropic.com/api/oauth/usage" \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Content-Type: application/json" 2>/dev/null)

if [ $? -ne 0 ] || echo "$RESPONSE" | grep -q '"error"'; then
  echo "C | size=12"
  echo "---"
  echo "API Error | color=#ef4444 size=12"
  echo "Token may be expired or rate limited | color=#888 size=11"
  echo "---"
  echo "Retry | refresh=true size=12"
  exit 0
fi

PARSED=$(echo "$RESPONSE" | python3 -c "
import sys, json
from datetime import datetime, timezone
d = json.load(sys.stdin)
s = d.get('five_hour', {}) or {}
w = d.get('seven_day', {}) or {}
su = round(s.get('utilization', 0))
wu = round(w.get('utilization', 0))

def time_left(iso):
    if not iso: return '—'
    diff = datetime.fromisoformat(iso) - datetime.now(timezone.utc)
    total_sec = int(diff.total_seconds())
    if total_sec <= 0: return 'now'
    h = total_sec // 3600
    m = (total_sec % 3600) // 60
    if h > 24:
        days = h // 24
        return f'{days}d_{h%24}h'
    if h > 0: return f'{h}h_{m}m'
    return f'{m}m'

sr = time_left(s.get('resets_at'))
wr = time_left(w.get('resets_at'))
print(f'{su}|{wu}|{sr}|{wr}')
" 2>/dev/null)

SESSION=$(echo "$PARSED" | cut -d'|' -f1)
WEEKLY=$(echo "$PARSED" | cut -d'|' -f2)
SESSION_RESET=$(echo "$PARSED" | cut -d'|' -f3 | tr '_' ' ')
WEEKLY_RESET=$(echo "$PARSED" | cut -d'|' -f4 | tr '_' ' ')

if [ -z "$SESSION" ]; then
  echo "C | size=12"
  echo "---"
  echo "Parse error | color=#ef4444 size=12"
  exit 0
fi

if [ "$SESSION" -ge 80 ]; then
  COLOR="#ef4444"
  STATUS="Critical"
elif [ "$SESSION" -ge 50 ]; then
  COLOR="#f59e0b"
  STATUS="Warning"
else
  COLOR="#10b981"
  STATUS="Good"
fi

if [ "$WEEKLY" -ge 80 ]; then
  WCOLOR="#ef4444"
elif [ "$WEEKLY" -ge 50 ]; then
  WCOLOR="#f59e0b"
else
  WCOLOR="#8b5cf6"
fi

# ── Menu bar: just text, no image (clean, scales with any mode) ──
echo "${SESSION}% | size=11 font=HelveticaNeue-Medium"

# ── Dropdown ──
echo "---"
echo "Claude Usage | size=14 color=#ffffff"
echo "${STATUS} | size=11 color=#666"
echo "---"

# 5-Hour Session
echo "Session (5h) | size=11 color=#999"
SESSION_BARS=$((SESSION / 5))
SESSION_EMPTY=$((20 - SESSION_BARS))
SESSION_BAR=$(printf '▓%.0s' $(seq 1 $SESSION_BARS 2>/dev/null) ; printf '░%.0s' $(seq 1 $SESSION_EMPTY 2>/dev/null))
echo "${SESSION_BAR}  ${SESSION}% | size=11 font=Menlo color=$COLOR"
echo "Resets in ${SESSION_RESET} | size=10 color=#555"
echo "---"

# 7-Day Weekly
echo "Weekly (7d) | size=11 color=#999"
WEEKLY_BARS=$((WEEKLY / 5))
WEEKLY_EMPTY=$((20 - WEEKLY_BARS))
WEEKLY_BAR=$(printf '▓%.0s' $(seq 1 $WEEKLY_BARS 2>/dev/null) ; printf '░%.0s' $(seq 1 $WEEKLY_EMPTY 2>/dev/null))
echo "${WEEKLY_BAR}  ${WEEKLY}% | size=11 font=Menlo color=$WCOLOR"
echo "Resets in ${WEEKLY_RESET} | size=10 color=#555"
echo "---"

echo "Open Dashboard | href=https://claude-usage-tracker-xi.vercel.app size=12"
echo "Refresh | refresh=true size=12"
echo "---"
echo "$(date '+%I:%M %p') | size=10 color=#444"
