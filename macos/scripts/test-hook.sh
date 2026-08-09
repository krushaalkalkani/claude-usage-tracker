#!/usr/bin/env bash
#
# End-to-end test for the Claude Code activity hook.
#
# Drives the hook with realistic payloads against a throwaway HOME and asserts the resulting
# session record — including that it never records prompt or assistant content.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/claude-activity-hook"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX"
SESSIONS="$SANDBOX/.claude-usage-tracker/sessions"
SID="11111111-2222-3333-4444-555555555555"
PASS=0
FAIL=0

fire() {
  local event="$1"; shift
  local payload="$1"; shift
  echo "$payload" | python3 "$HOOK" "$event" "$@" >/dev/null 2>&1
}

record() { cat "$SESSIONS/$SID.json" 2>/dev/null; }

assert() {
  local label="$1" expr="$2"
  if python3 -c "
import json,sys
try:
    d = json.load(open('$SESSIONS/$SID.json'))
except Exception:
    d = {}
sys.exit(0 if ($expr) else 1)
" 2>/dev/null; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$label"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n     got: %s\n' "$label" "$(record)"
  fi
}

assert_no_file() {
  local label="$1"
  if [ ! -f "$SESSIONS/$SID.json" ]; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$label"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$label"
  fi
}

base() {
  cat <<JSON
{"session_id":"$SID","cwd":"/Users/x/projects/my-repo","permission_mode":"default",
 "effort":{"level":"high"},"hook_event_name":"$1"$2}
JSON
}

echo "hook: $HOOK"
echo "sandbox HOME: $SANDBOX"
echo

echo "SessionStart"
fire SessionStart "$(base SessionStart ',"source":"startup"')"
assert "creates the record"          "d.get('sessionId') == '$SID'"
assert "captures project from cwd"   "d.get('project') == 'my-repo'"
assert "starts idle"                 "d.get('status') == 'idle'"
assert "records the Claude Code pid" "isinstance(d.get('claudePid'), int) and d['claudePid'] > 0"
assert "captures effort"             "d.get('effort') == 'high'"

echo "UserPromptSubmit (with prompt text that must NOT be stored)"
fire UserPromptSubmit "$(base UserPromptSubmit ',"user_input":"SECRET-PROMPT-TEXT-XYZZY"')"
assert "goes to working"             "d.get('status') == 'working'"
assert "starts the turn clock"       "d.get('turnStartedAt') is not None"
if grep -q "XYZZY" "$SESSIONS/$SID.json" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL prompt text leaked into the session record"
else
  PASS=$((PASS+1)); echo "  ok   prompt text is not recorded"
fi

echo "PreToolUse (tool input must NOT be stored)"
fire PreToolUse "$(base PreToolUse ',"tool_name":"Bash","tool_input":{"command":"echo SECRET-ARG-QUUX"},"tool_use_id":"toolu_1"')"
assert "status running_tool"         "d.get('status') == 'running_tool'"
assert "records the tool NAME"       "d.get('statusDetail') == 'Bash'"
if grep -q "QUUX" "$SESSIONS/$SID.json" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL tool input leaked into the session record"
else
  PASS=$((PASS+1)); echo "  ok   tool input is not recorded"
fi

echo "PostToolUse"
fire PostToolUse "$(base PostToolUse ',"tool_name":"Bash","tool_response":"SECRET-OUTPUT-PLUGH"')"
assert "back to working"             "d.get('status') == 'working'"
assert "clears the tool detail"      "d.get('statusDetail') is None"
if grep -q "PLUGH" "$SESSIONS/$SID.json" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL tool output leaked into the session record"
else
  PASS=$((PASS+1)); echo "  ok   tool output is not recorded"
fi

echo "Subagents"
fire SubagentStart "$(base SubagentStart ',"agent_type":"Explore"')"
fire SubagentStart "$(base SubagentStart ',"agent_type":"Plan"')"
assert "counts two agents"           "d.get('activeAgents') == 2"
assert "status running_agents"       "d.get('status') == 'running_agents'"
fire SubagentStop "$(base SubagentStop ',"agent_type":"Explore"')"
assert "decrements to one"           "d.get('activeAgents') == 1"
fire SubagentStop "$(base SubagentStop ',"agent_type":"Plan"')"
assert "returns to working at zero"  "d.get('activeAgents') == 0 and d.get('status') == 'working'"

echo "Tasks"
fire TaskCreated "$(base TaskCreated '')"
fire TaskCreated "$(base TaskCreated '')"
fire TaskCompleted "$(base TaskCompleted '')"
assert "tracks open tasks"           "d.get('openTasks') == 1"

echo "PermissionRequest"
fire PermissionRequest "$(base PermissionRequest ',"tool_name":"Write"')"
assert "needs attention"             "d.get('needsAttention') is True"
assert "status permission_required"  "d.get('status') == 'permission_required'"
assert "explains why"                "d.get('attentionReason') == 'Permission requested'"

echo "Notification: idle_prompt"
fire Notification "$(base Notification ',"type":"idle_prompt","message":"Claude is waiting for your input"')"
assert "status waiting_for_user"     "d.get('status') == 'waiting_for_user'"

echo "Notification: unrelated type does not change status"
fire Notification "$(base Notification ',"type":"auth_success","message":"Signed in"')"
assert "status unchanged"            "d.get('status') == 'waiting_for_user'"

echo "PostToolUseFailure"
fire UserPromptSubmit "$(base UserPromptSubmit '')"
fire PostToolUseFailure "$(base PostToolUseFailure ',"tool_name":"Edit"')"
assert "records the failing tool"    "d.get('lastError') == 'Edit'"
assert "the turn keeps going"        "d.get('status') == 'working'"

echo "Compaction"
fire PreCompact "$(base PreCompact ',"trigger":"auto"')"
assert "status compacting"           "d.get('status') == 'compacting'"
fire PostCompact "$(base PostCompact ',"trigger":"auto"')"
assert "resumes working"             "d.get('status') == 'working'"

echo "Stop (assistant text must NOT be stored)"
python3 - <<PY
import json, os, time, calendar
p = "$SESSIONS/$SID.json"
d = json.load(open(p))
# Backdate the turn start so the duration is measurable and deterministic.
d["turnStartedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 125))
json.dump(d, open(p, "w"))
PY
fire Stop "$(base Stop ',"last_assistant_message":"SECRET-REPLY-FROBOZZ"')"
assert "status completed"            "d.get('status') == 'completed'"
assert "clears attention"            "d.get('needsAttention') is False"
assert "measures the turn (~125s)"   "120 <= (d.get('lastTurnSeconds') or 0) <= 131"
assert "stamps completion"           "d.get('lastCompletedAt') is not None"
if grep -q "FROBOZZ" "$SESSIONS/$SID.json" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL assistant text leaked into the session record"
else
  PASS=$((PASS+1)); echo "  ok   assistant text is not recorded"
fi

echo "StopFailure with rate_limit hint"
fire StopFailure "$(base StopFailure '')" rate_limit
assert "status rate_limited"         "d.get('status') == 'rate_limited'"
assert "attention set"               "d.get('needsAttention') is True"
assert "hint is not persisted"       "'_hint' not in d"

echo "StopFailure, other class"
fire StopFailure "$(base StopFailure ',"reason":"server_error"')"
assert "status error"                "d.get('status') == 'error'"

echo "Robustness"
echo 'not json at all' | python3 "$HOOK" PostToolUse >/dev/null 2>&1
assert "garbage stdin is ignored"    "d.get('sessionId') == '$SID'"
echo '{}' | python3 "$HOOK" PostToolUse >/dev/null 2>&1
assert "payload with no session id ignored" "d.get('sessionId') == '$SID'"
OUT="$(echo "$(base PostToolUse '')" | python3 "$HOOK" PostToolUse 2>/dev/null)"
if [ -z "$OUT" ]; then
  PASS=$((PASS+1)); echo "  ok   writes nothing to stdout"
else
  FAIL=$((FAIL+1)); echo "  FAIL wrote to stdout: $OUT"
fi
echo "$(base PostToolUse '')" | python3 "$HOOK" PostToolUse >/dev/null 2>&1
if [ $? -eq 0 ]; then
  PASS=$((PASS+1)); echo "  ok   always exits 0"
else
  FAIL=$((FAIL+1)); echo "  FAIL non-zero exit"
fi

echo "Path traversal in session_id"
echo '{"session_id":"../../escaped","cwd":"/tmp","hook_event_name":"SessionStart"}' \
  | python3 "$HOOK" SessionStart >/dev/null 2>&1
if [ -f "$SANDBOX/.claude-usage-tracker/escaped.json" ] || [ -f "$SANDBOX/escaped.json" ]; then
  FAIL=$((FAIL+1)); echo "  FAIL a crafted session id escaped the sessions directory"
else
  PASS=$((PASS+1)); echo "  ok   session id is sanitized into a safe filename"
fi

echo "Rollup"
if python3 -c "
import json,sys
d = json.load(open('$SANDBOX/.claude-usage-tracker/activity.json'))
sys.exit(0 if d.get('schema') == 1 and d.get('sessionCount', 0) >= 1 else 1)
" 2>/dev/null; then
  PASS=$((PASS+1)); echo "  ok   activity.json rollup is written"
else
  FAIL=$((FAIL+1)); echo "  FAIL rollup missing or malformed"
fi

echo "Event ring buffer"
LINES=$(wc -l < "$SANDBOX/.claude-usage-tracker/events.jsonl" 2>/dev/null || echo 0)
if [ "$LINES" -gt 0 ]; then
  PASS=$((PASS+1)); echo "  ok   events.jsonl has $LINES entries"
else
  FAIL=$((FAIL+1)); echo "  FAIL no events recorded"
fi
if grep -qE 'XYZZY|QUUX|PLUGH|FROBOZZ' "$SANDBOX/.claude-usage-tracker/events.jsonl" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL content leaked into events.jsonl"
else
  PASS=$((PASS+1)); echo "  ok   events.jsonl holds event names only"
fi

echo "SessionEnd"
fire SessionEnd "$(base SessionEnd ',"reason":"clear"')"
assert_no_file "removes the session record"

echo
echo "-------------------------------"
printf "passed: %d   failed: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
