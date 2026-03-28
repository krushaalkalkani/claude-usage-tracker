#!/bin/bash

# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

TOKEN_FILE="$HOME/.claude-usage-token"

if [ ! -f "$TOKEN_FILE" ]; then
  echo "C — | size=12"
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
  echo "C — | size=12"
  echo "---"
  echo "API Error — token may be expired | color=#ef4444 size=12"
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
  echo "C — | size=12"
  echo "---"
  echo "Parse error | color=#ef4444 size=12"
  exit 0
fi

# SF Symbol color based on usage
if [ "$SESSION" -ge 80 ]; then
  SFCOLOR="#ef4444"
  COLOR="#ef4444"
  WSTATUS="Critical"
elif [ "$SESSION" -ge 50 ]; then
  SFCOLOR="#f59e0b"
  COLOR="#f59e0b"
  WSTATUS="Moderate"
else
  SFCOLOR="#10b981"
  COLOR="#10b981"
  WSTATUS="Good"
fi

if [ "$WEEKLY" -ge 80 ]; then
  WCOLOR="#ef4444"
elif [ "$WEEKLY" -ge 50 ]; then
  WCOLOR="#f59e0b"
else
  WCOLOR="#8b5cf6"
fi

# ── Generate compact menu bar icon ──
ICON_B64=$(python3 -c "
import base64, io
from PIL import Image, ImageDraw, ImageFont

pct = ${SESSION}
color = '${COLOR}'

cr = int(color[1:3], 16)
cg = int(color[3:5], 16)
cb = int(color[5:7], 16)

text = str(pct)
try:
    font = ImageFont.truetype('/System/Library/Fonts/HelveticaNeue.ttc', 12, index=7)
except:
    font = ImageFont.load_default()

# Measure text to fit snugly
tmp = Image.new('RGBA', (1, 1))
bbox = ImageDraw.Draw(tmp).textbbox((0, 0), text, font=font)
tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]

pad = 4
SZ = th + pad * 2 + 2
if tw + pad * 2 > SZ:
    SZ = tw + pad * 2 + 2

img = Image.new('RGBA', (SZ, SZ), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# Square with max rounding (like Notion icon)
d.rounded_rectangle([0, 0, SZ-1, SZ-1], radius=SZ//3, fill=(0, 0, 0, 0), outline=(40, 40, 40, 220), width=1)

# Centered text
tx = (SZ - tw) // 2 - bbox[0]
ty = (SZ - th) // 2 - bbox[1]
d.text((tx, ty), text, fill=(30, 30, 30, 230), font=font)

buf = io.BytesIO()
img.save(buf, format='PNG')
print(base64.b64encode(buf.getvalue()).decode())
")

# ── Menu Bar — Notion-style icon only ──
echo "| image=$ICON_B64 size=12"

# ── Dropdown ──
echo "---"
echo "Claude Usage · ${WSTATUS} | size=13 color=#ffffff"
echo "---"

# 5-Hour Session
echo "5-Hour Session | size=12 color=#999"
SESSION_BARS=$((SESSION / 5))
SESSION_EMPTY=$((20 - SESSION_BARS))
SESSION_BAR=$(printf '▓%.0s' $(seq 1 $SESSION_BARS 2>/dev/null) ; printf '░%.0s' $(seq 1 $SESSION_EMPTY 2>/dev/null))
echo "${SESSION_BAR}  ${SESSION}% | size=12 font=Menlo color=$COLOR"
echo "Resets in ${SESSION_RESET} | size=11 color=#666"
echo "---"

# 7-Day Weekly
echo "7-Day Weekly | size=12 color=#999"
WEEKLY_BARS=$((WEEKLY / 5))
WEEKLY_EMPTY=$((20 - WEEKLY_BARS))
WEEKLY_BAR=$(printf '▓%.0s' $(seq 1 $WEEKLY_BARS 2>/dev/null) ; printf '░%.0s' $(seq 1 $WEEKLY_EMPTY 2>/dev/null))
echo "${WEEKLY_BAR}  ${WEEKLY}% | size=12 font=Menlo color=$WCOLOR"
echo "Resets in ${WEEKLY_RESET} | size=11 color=#666"
echo "---"

echo "Open Dashboard | href=http://localhost:5173 size=12"
echo "Refresh | refresh=true size=12"
echo "---"
echo "$(date '+%I:%M %p') | size=10 color=#555"
