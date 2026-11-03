#!/usr/bin/env bash
# The two hooks: arming, injection, the one-refusal Stop gate, escapes.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
H="$root/skills/counterpoint/hooks"
payload() { printf '{"session_id":"%s","prompt":"%s"}' "$1" "$2"; }

out="$(payload s1 "hello" | bash "$H/prompt.sh")"; rc=$?
ok "mode off: prompt hook exits 0" "$rc" 0
ok "mode off: silent" "$out" ""
[ -f "$COUNTERPOINT_HOME/sessions/s1/turn" ] && r=yes || r=no
ok "a turn is stamped even when off" "$r" yes
out="$(payload s1 "" | bash "$H/stop.sh" 2>&1)"; rc=$?
ok "unarmed turn: stop is allowed" "$rc" 0

"$CP" mode small >/dev/null
out="$(payload s1 "do the thing" | bash "$H/prompt.sh")"
has "toggle small injects the directive" "$out" "mode=small"
has "and points at done/skip" "$out" "counterpoint skip"
turn="$(cat "$COUNTERPOINT_HOME/sessions/s1/turn")"
ok "the turn is armed small" "$(cat "$COUNTERPOINT_HOME/turns/$turn/mode")" small
out="$(payload s1 "" | bash "$H/stop.sh" 2>&1)"; rc=$?
ok "first incomplete stop is refused" "$rc" 2
has "with a reason that names done" "$out" "counterpoint done"
out="$(payload s1 "" | bash "$H/stop.sh" 2>&1)"; rc=$?
ok "second stop goes through" "$rc" 0
has "and is logged as an escape" "$(cat "$COUNTERPOINT_HOME/escapes.log")" "turn=$turn"

payload s1 "next" | bash "$H/prompt.sh" >/dev/null
CLAUDE_CODE_SESSION_ID=s1 "$CP" skip "a question" >/dev/null 2>&1
out="$(payload s1 "" | bash "$H/stop.sh" 2>&1)"; rc=$?
ok "a skipped turn stops cleanly" "$rc" 0

"$CP" mode off >/dev/null
out="$(payload s2 "/counterpoint full refactor it" | bash "$H/prompt.sh")"
ok "manual /counterpoint does not inject (the slash command loads the skill)" "$out" ""
turn="$(cat "$COUNTERPOINT_HOME/sessions/s2/turn")"
ok "manual /counterpoint full arms the turn full" "$(cat "$COUNTERPOINT_HOME/turns/$turn/mode")" full
out="$(payload s2 "" | bash "$H/stop.sh" 2>&1)"; rc=$?
ok "manual turn is enforced too" "$rc" 2
payload s2 "plain prompt" | bash "$H/prompt.sh" >/dev/null
out="$(payload s2 "" | bash "$H/stop.sh" 2>&1)"; rc=$?
ok "the next plain prompt is not armed" "$rc" 0

out="$(printf 'not json' | bash "$H/prompt.sh" 2>&1)"; rc=$?
ok "malformed payload never breaks the prompt" "$rc" 0
out="$(printf 'not json' | bash "$H/stop.sh" 2>&1)"; rc=$?
ok "malformed payload never blocks a stop" "$rc" 0

# sessions do not see each other's turns
"$CP" mode small >/dev/null
payload sA "x" | bash "$H/prompt.sh" >/dev/null
payload sB "y" | bash "$H/prompt.sh" >/dev/null
CLAUDE_CODE_SESSION_ID=sA "$CP" skip "done in A" >/dev/null 2>&1
out="$(payload sB "" | bash "$H/stop.sh" 2>&1)"; rc=$?
ok "closing session A does not close session B" "$rc" 2
"$CP" mode off >/dev/null
finish
