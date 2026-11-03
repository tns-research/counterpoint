#!/usr/bin/env bash
# Codex starts from env -i: secrets in the caller's environment never cross.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
export SUPER_SECRET_TOKEN=leak OPENAI_API_KEY=leak2
"$CP" review --turn e1 --ask x --draft a.sh >/dev/null 2>&1
names="$(cat "$COUNTERPOINT_FAKE_LOG.env")"
case "$names" in *SUPER_SECRET_TOKEN*) r=leaked ;; *) r=clean ;; esac
ok "an unrelated secret does not reach Codex" "$r" clean
case "$names" in *OPENAI_API_KEY*) r=leaked ;; *) r=clean ;; esac
ok "OPENAI_API_KEY does not reach Codex by default" "$r" clean
has "HOME does" "$names" "HOME"
COUNTERPOINT_CODEX_ENV_PASSTHROUGH="$COUNTERPOINT_CODEX_ENV_PASSTHROUGH,OPENAI_API_KEY" "$CP" review --turn e2 --ask x --draft a.sh >/dev/null 2>&1
has "an explicit passthrough does" "$(cat "$COUNTERPOINT_FAKE_LOG.env")" "OPENAI_API_KEY"
out="$(COUNTERPOINT_CODEX_ENV_PASSTHROUGH="$COUNTERPOINT_CODEX_ENV_PASSTHROUGH,bad-name" "$CP" review --turn e3 --ask x --draft a.sh 2>&1)"
has "a malformed passthrough name is dropped with a warning" "$out" "malformed passthrough name: bad-name"
finish
