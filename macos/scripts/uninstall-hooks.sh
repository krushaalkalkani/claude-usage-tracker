#!/usr/bin/env bash
#
# Removes every Claude Usage Tracker hook entry from Claude Code's settings.
# Other hooks are left exactly as they were.
#
#   ./uninstall-hooks.sh             → ~/.claude/settings.json
#   ./uninstall-hooks.sh --project   → ./.claude/settings.json
#   ./uninstall-hooks.sh --purge     → also delete ~/.claude-usage-tracker/sessions
#
set -euo pipefail

SCOPE="user"
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --project) SCOPE="project" ;;
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$SCOPE" = "project" ]; then
  SETTINGS="$(pwd)/.claude/settings.json"
else
  SETTINGS="$HOME/.claude/settings.json"
fi

if [ ! -f "$SETTINGS" ]; then
  echo "no settings file at $SETTINGS — nothing to do" >&2
else
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  SETTINGS="$SETTINGS" python3 <<'PY'
import json, os, sys

path = os.environ["SETTINGS"]
MARKER = "claude-activity-hook"

with open(path) as fh:
    settings = json.load(fh)

hooks = settings.get("hooks")
removed = 0
if isinstance(hooks, dict):
    for event in list(hooks):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        for group in groups:
            if isinstance(group, dict) and isinstance(group.get("hooks"), list):
                before = len(group["hooks"])
                group["hooks"] = [
                    h for h in group["hooks"]
                    if not (isinstance(h, dict) and MARKER in str(h.get("command", "")))
                ]
                removed += before - len(group["hooks"])
        hooks[event] = [
            g for g in groups
            if not (isinstance(g, dict) and not g.get("hooks"))
        ]
        if not hooks[event]:
            del hooks[event]
    if not hooks:
        settings.pop("hooks", None)

tmp = path + ".tmp"
with open(tmp, "w") as fh:
    fh.write(json.dumps(settings, indent=2) + "\n")
os.replace(tmp, path)
print("removed %d hook entries from %s" % (removed, path), file=sys.stderr)
PY
fi

if [ "$PURGE" -eq 1 ]; then
  rm -rf "$HOME/.claude-usage-tracker/sessions" \
         "$HOME/.claude-usage-tracker/events.jsonl" \
         "$HOME/.claude-usage-tracker/activity.json"
  echo "purged local activity state" >&2
fi
