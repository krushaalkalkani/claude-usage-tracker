#!/usr/bin/env bash
#
# Registers the Claude Usage Tracker activity hook with Claude Code.
#
# Idempotent: re-running replaces our entries and leaves every other hook untouched.
# A timestamped backup of settings.json is written before any change.
#
#   ./install-hooks.sh              → ~/.claude/settings.json   (all projects)
#   ./install-hooks.sh --project    → ./.claude/settings.json   (this project only)
#   ./install-hooks.sh --dry-run    → print the merged file, write nothing
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/claude-activity-hook"
SCOPE="user"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --project) SCOPE="project" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ ! -f "$HOOK" ]; then
  echo "hook script not found at $HOOK" >&2
  exit 1
fi
chmod +x "$HOOK"
HOOK="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")"

if [ "$SCOPE" = "project" ]; then
  SETTINGS="$(pwd)/.claude/settings.json"
else
  SETTINGS="$HOME/.claude/settings.json"
fi
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

if [ "$DRY_RUN" -eq 0 ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
fi

HOOK_PATH="$HOOK" DRY_RUN="$DRY_RUN" SETTINGS="$SETTINGS" python3 <<'PY'
import json, os, sys

hook = os.environ["HOOK_PATH"]
settings_path = os.environ["SETTINGS"]
dry = os.environ["DRY_RUN"] == "1"

MARKER = "claude-activity-hook"

# (event, matcher, extra_args)
#
# Every entry is async so Claude Code never waits on us, and observability-only: the hook
# writes no stdout and always exits 0.
EVENTS = [
    ("SessionStart",       None,                 []),
    ("SessionEnd",         None,                 []),
    ("UserPromptSubmit",   None,                 []),
    ("PreToolUse",         None,                 []),
    ("PostToolUse",        None,                 []),
    ("PostToolUseFailure", None,                 []),
    ("PermissionRequest",  None,                 []),
    ("Notification",       None,                 []),
    ("SubagentStart",      None,                 []),
    ("SubagentStop",       None,                 []),
    ("TaskCreated",        None,                 []),
    ("TaskCompleted",      None,                 []),
    ("TeammateIdle",       None,                 []),
    ("PreCompact",         None,                 []),
    ("PostCompact",        None,                 []),
    ("Stop",               None,                 []),
    # The StopFailure payload's error-class field name is undocumented, so we register two
    # entries and pass the class positionally. The second matcher excludes rate_limit so
    # exactly one of them fires.
    ("StopFailure",        "rate_limit",         ["rate_limit"]),
    ("StopFailure",        "^(?!rate_limit$).+", []),
]

with open(settings_path) as fh:
    try:
        settings = json.load(fh)
    except json.JSONDecodeError as exc:
        sys.exit("%s is not valid JSON (%s) — fix it before installing hooks." % (settings_path, exc))

if not isinstance(settings, dict):
    sys.exit("%s does not contain a JSON object." % settings_path)

hooks = settings.setdefault("hooks", {})
if not isinstance(hooks, dict):
    sys.exit("`hooks` in %s is not an object." % settings_path)

installed = 0
# Group by event first. An event with more than one matcher (StopFailure) must be cleaned
# ONCE and then have all of its entries appended — cleaning per matcher would make the
# second pass delete the entry the first pass just added.
by_event = {}
for event, matcher, extra in EVENTS:
    by_event.setdefault(event, []).append((matcher, extra))

for event, variants in by_event.items():
    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list):
        sys.exit("hooks.%s in %s is not an array." % (event, settings_path))

    # Drop any previous entry of ours for this event, keep everyone else's.
    for group in groups:
        if isinstance(group, dict) and isinstance(group.get("hooks"), list):
            group["hooks"] = [
                h for h in group["hooks"]
                if not (isinstance(h, dict) and MARKER in str(h.get("command", "")))
            ]
    # Remove groups we emptied out. A group with no hooks left is ours to clean up whether or
    # not it carries our marker — an empty group does nothing either way.
    groups[:] = [g for g in groups if not (isinstance(g, dict) and g.get("hooks") == [])]

    for matcher, extra in variants:
        entry = {
            "type": "command",
            "command": hook,
            "args": [event] + extra,
            "async": True,
            "timeout": 10,
        }
        group = {"hooks": [entry], "_claudeUsageTracker": True}
        if matcher:
            group["matcher"] = matcher
        groups.append(group)
        installed += 1

# Remove event keys we emptied out entirely.
for event in list(hooks):
    if hooks[event] == []:
        del hooks[event]

blob = json.dumps(settings, indent=2) + "\n"
if dry:
    sys.stdout.write(blob)
else:
    tmp = settings_path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(blob)
    os.replace(tmp, settings_path)

print("registered %d hook entries -> %s" % (installed, settings_path), file=sys.stderr)
PY

if [ "$DRY_RUN" -eq 1 ]; then
  echo "(dry run — nothing written)" >&2
  exit 0
fi

mkdir -p "$HOME/.claude-usage-tracker/sessions"
chmod 700 "$HOME/.claude-usage-tracker"

cat >&2 <<EOF

Done. Activity tracking starts with your NEXT Claude Code session
(already-running sessions have no hooks loaded).

  State:    ~/.claude-usage-tracker/sessions/
  Remove:   $SCRIPT_DIR/uninstall-hooks.sh
EOF
