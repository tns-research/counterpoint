#!/usr/bin/env bash
# Executable repros and the project memory, end to end against the fake codex.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

reply_with() { # reply_with FILE COMMAND CONTENT [SEVERITY] [CATEGORY]
  python3 -c 'import json,sys; f,c,b,s,k=sys.argv[1:6]; print(json.dumps({"verdict":"fix","summary":"s","findings":[{"id":"F1","severity":s,"category":k,"where":"calc.sh:2","problem":"adds wrong","evidence":"e","fix":"f","repro":{"file":f,"command":c,"content":b}}]}))' "$1" "$2" "$3" "${4:-major}" "${5:-correctness}"
}
mkdir -p p && (cd p && git init -q && printf '#!/bin/sh\necho $(( $1 - $2 ))\n' > calc.sh && git add calc.sh && git -c user.email=a@b -c user.name=a commit -qm i && echo '# wip' >> calc.sh)
test_body='r="$(sh ./calc.sh 2 3)"; if [ "$r" = 5 ]; then echo "COUNTERPOINT-REPRO: PASS"; exit 0; else echo "got $r"; echo "COUNTERPOINT-REPRO: FAIL"; exit 1; fi'

export COUNTERPOINT_FAKE_REPLY="$(reply_with repro_f1.sh 'bash "$REPRO"' "$test_body")"
out="$("$CP" review --turn q1 --ask "add two numbers" --diff -C p 2>&1)"; rc=$?
ok "a review with a repro exits 0" "$rc" 0
has "the repro reproduces the bug" "$out" "repro F1: REPRODUCED"
has "the category is shown" "$out" "F1 [major/correctness]"
has "the prompt asks for repros" "$(cat "$COUNTERPOINT_FAKE_LOG.stdin")" "COUNTERPOINT-REPRO: FAIL"
[ -e p/repro_f1.sh ] && r=yes || r=no
ok "the test never lands in the real project" "$r" no
ok "the project is untouched" "$(cd p && git status --porcelain)" " M calc.sh"

printf 'F1 applied\n' > lq.md
out="$("$CP" done --turn q1 --final p/calc.sh --ledger lq.md 2>&1)"; rc=$?
ok "done refuses a reproduced bug with no passing repro" "$rc" 2
has "and says to run verify" "$out" "counterpoint verify"
out="$("$CP" verify --turn q1 2>&1)"; rc=$?
ok "verify before the fix exits 5" "$rc" 5
has "and reports the bug is still there" "$out" "STILL FAILS"
out="$("$CP" done --turn q1 --final p/calc.sh --ledger lq.md 2>&1)"; rc=$?
ok "done refuses a fix whose repro still fails" "$rc" 2
printf '#!/bin/sh\necho $(( $1 + $2 ))\n' > p/calc.sh
out="$("$CP" verify --turn q1 2>&1)"; rc=$?
ok "verify after the fix exits 0" "$rc" 0
has "and shows the test passing" "$out" "after the fix: test passes"
out="$("$CP" done --turn q1 --final p/calc.sh --ledger lq.md 2>&1)"; rc=$?
ok "done accepts a proven fix" "$rc" 0

# a repro that passes on the reviewed code flags a likely false positive
out="$("$CP" review --turn q2 --ask x --diff -C p 2>&1)"
has "a passing repro is reported as not reproduced" "$out" "NOT reproduced"
out="$("$CP" done --turn q2 --final p/calc.sh --ledger lq.md 2>&1)"; rc=$?
ok "applying it anyway is allowed" "$rc" 0
has "with a warning" "$out" "was it a real bug?"

# broken, slow and env-probing repros
export COUNTERPOINT_FAKE_REPLY="$(reply_with r.sh 'no-such-tool "$REPRO"' "$test_body")"
has "a broken repro is inconclusive" "$("$CP" review --turn q3 --ask x --diff -C p 2>&1)" "inconclusive: exit 127"
export COUNTERPOINT_FAKE_REPLY="$(reply_with r.sh 'bash "$REPRO"' 'sleep 20')"
s=$(date +%s)
has "a slow repro is cut at its bound" "$(COUNTERPOINT_REPRO_TIMEOUT=1 "$CP" review --turn q4 --ask x --diff -C p 2>&1)" "hit the 1s bound"
[ $(( $(date +%s) - s )) -le 15 ] && r=yes || r=no
ok "quickly" "$r" yes
export COUNTERPOINT_FAKE_REPLY="$(reply_with r.sh 'bash "$REPRO"' 'env > "$TMPDIR/cp-env.txt" 2>/dev/null || env > /tmp/cp-env-$$.txt; echo "COUNTERPOINT-REPRO: PASS"')"
SECRET_TOKEN_X=leak "$CP" review --turn q5 --ask x --diff -C p >/dev/null 2>&1
has "the repro ran" "$(cat "$COUNTERPOINT_HOME/turns/q5/runs/01-review/repro/F1/before")" "passes"
envdump="$(cat "${TMPDIR:-/tmp}"/cp-env.txt /tmp/cp-env-*.txt 2>/dev/null)"
case "$envdump" in *SECRET_TOKEN_X*) r=leaked ;; *) r=clean ;; esac
ok "the caller's secrets never reach a repro" "$r" clean
rm -f "${TMPDIR:-/tmp}"/cp-env.txt /tmp/cp-env-*.txt

# the dogfood review's three findings, as regressions
export COUNTERPOINT_FAKE_REPLY="$(reply_with r.sh 'bash "$REPRO"' 'echo "COUNTERPOINT-REPRO: FAIL"; no-such-tool')"
has "a FAIL marker with a crash is inconclusive" "$("$CP" review --turn q7 --ask x --diff -C p 2>&1)" "inconclusive: exit 127"
export COUNTERPOINT_FAKE_REPLY="$(reply_with r.sh 'bash "$REPRO"' 'echo "COUNTERPOINT-REPRO: FAILED"; exit 1')"
has "a partial marker is inconclusive" "$("$CP" review --turn q8 --ask x --diff -C p 2>&1)" "inconclusive: exit 1"
mkdir -p v && (cd v && git init -q && echo victim > victim.sh && echo taken > repro_f1.sh && ln -s "$PWD/victim.sh" cp_F1_repro_f1.sh && git add -A && git -c user.email=a@b -c user.name=a commit -qm i)
export COUNTERPOINT_FAKE_REPLY="$(reply_with repro_f1.sh 'bash "$REPRO"' 'echo "COUNTERPOINT-REPRO: PASS"')"
"$CP" review --turn q9 --ask x --diff -C v >/dev/null 2>&1
ok "a repro never writes through a symlink into the project" "$(cat v/victim.sh)" victim
ok "and still runs" "$(cat "$COUNTERPOINT_HOME/turns/q9/runs/01-review/repro/F1/before")" passes
export COUNTERPOINT_FAKE_REPLY="$(reply_with repro_f1.sh 'bash "$REPRO"' "$test_body")"
"$CP" review --turn q10 --ask x --diff -C p >/dev/null 2>&1
printf 'fails\n' > "$COUNTERPOINT_HOME/turns/q10/runs/01-review/repro/F1/before"
printf 'inconclusive: hit the 30s bound\n' > "$COUNTERPOINT_HOME/turns/q10/runs/01-review/repro/F1/after"
out="$("$CP" done --turn q10 --final p/calc.sh --ledger lq.md 2>&1)"; rc=$?
ok "an inconclusive repro after the fix does not close the turn" "$rc" 2

# --no-repro: not asked, not run
export COUNTERPOINT_FAKE_REPLY="$(reply_with repro_f1.sh 'bash "$REPRO"' "$test_body")"
"$CP" review --turn q6 --ask x --diff -C p --no-repro >/dev/null 2>&1
has "--no-repro tells Codex to leave repro null" "$(cat "$COUNTERPOINT_FAKE_LOG.stdin")" 'Set "repro" to null'
[ -d "$COUNTERPOINT_HOME/turns/q6/runs/01-review/repro" ] && r=yes || r=no
ok "and runs nothing" "$r" no

# memory: a rejection is recorded and shown to the next review
export COUNTERPOINT_FAKE_REPLY="$(reply_with r.sh 'bash "$REPRO"' "$test_body" minor clarity)"
"$CP" review --turn m1 --ask x --diff -C p >/dev/null 2>&1
printf 'F1 rejected: the name is the project convention\n' > lm.md
"$CP" done --turn m1 --final p/calc.sh --ledger lm.md >/dev/null 2>&1
"$CP" review --turn m2 --ask x --diff -C p >/dev/null 2>&1
prompt="$(cat "$COUNTERPOINT_FAKE_LOG.stdin")"
has "the next review sees the project's rejections" "$prompt" "Already examined and rejected in this project"
has "with the reason" "$prompt" "(rejected: the name is the project convention)"
"$CP" review --turn m3 --ask x --diff -C p --no-memory >/dev/null 2>&1
case "$(cat "$COUNTERPOINT_FAKE_LOG.stdin")" in *"Already examined"*) r=shown ;; *) r=absent ;; esac
ok "--no-memory leaves them out" "$r" absent
"$CP" review --turn m4 --ask x --draft a.sh >/dev/null 2>&1
case "$(cat "$COUNTERPOINT_FAKE_LOG.stdin")" in *"name is the project convention"*) r=leaked ;; *) r=scoped ;; esac
ok "another project does not see them" "$r" scoped
out="$("$CP" stats -C p 2>&1)"
has "stats lists the category" "$out" "clarity"
has "stats counts the turns' findings" "$out" "all"
has "stats reports the repros" "$out" "reproduced"
"$CP" done --turn m1 --final p/calc.sh --ledger lm.md >/dev/null 2>&1
ok "a re-run done records nothing twice" "$(cat "$COUNTERPOINT_HOME"/projects/*/history.jsonl | grep -c '"turn":"m1"')" 1
"$CP" forget -C p >/dev/null 2>&1
has "forget clears the history" "$("$CP" stats -C p 2>&1)" "no recorded findings"

finish
