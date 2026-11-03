---
name: counterpoint
description: Use Claude and OpenAI Codex together on one task. Small mode: Claude produces, Codex (codex CLI, ChatGPT subscription) reviews with grounded findings and executable bug tests, Claude verifies each finding and decides. Full mode: both plan independently, Codex judges the two plans blind, the better author produces, the other reviews, and Codex rechecks the fixes. Use when a second model from another lab should catch blind spots before shipping code, a document, or an analysis.
---

# counterpoint

One CLI does the Codex side: `<skill_dir>/bin/counterpoint` (call it `cp` below; resolve `<skill_dir>` to this skill's directory). Every Codex call is time-bounded and recorded under `~/.counterpoint/turns/<turn>/`; review, plan, compare and recheck are read-only, and only `produce --write` lets Codex edit files. Run `cp help` for flags.

**Depth.** `/counterpoint full <task>` or the toggle at `full` means full mode. Anything else means small mode.

**First command of every task:** `cp start small` or `cp start full`. It opens a turn for this task, so its runs and checks never mix with another task's, and sets the depth `cp done` enforces.

## The three rules that make it work

1. **Codex findings are hypotheses.** A reviewer that cannot run your tests is wrong often enough to make code worse if obeyed blindly. Before applying a finding, check it: run the failing input, read the cited line, re-read the constraint. Apply what holds and reject what does not, with a reason.
2. **Parity.** Hand Codex what you were given: the request (`--brief` or `--ask`, verbatim) and every document that constrains it (`--context AGENTS.md`, the skill, the spec). A constraint the reviewer never read is one it cannot check.
3. **Never block on Codex.** Launch with `--bg`, keep working (tests, your own checks), then `cp wait`.

## Small mode: produce, review, decide, ship

1. Produce the work as usual (edit files, write the document).
2. Review it, in the background:
   - code: `cp review --diff --brief request.md --context AGENTS.md --bg`
   - a document or any file: `cp review --draft out.md --brief request.md --context AGENTS.md --bg`
3. While Codex reads, run the tests, linters, or your own pass. Then `cp wait`.
   Blocker and major findings on runnable code may come with a repro, already run on a copy of the reviewed code: `REPRODUCED` is a proven bug, `NOT reproduced` is a likely false positive (or a wrong test: read it), `inconclusive` means judge it by hand as usual.
4. For every finding: verify (rule 1), then fix or reject. After fixing, `cp verify` re-runs the repros on the fixed code (under a second); `cp done` refuses a reproduced bug marked applied until its repro passes. Write a ledger, one line per finding:
   ```
   F1 applied
   F2 rejected: the cited input is rejected earlier by parse_args (line 40)
   F3 deferred: out of scope for this change, noted in the PR
   ```
5. `cp done --final <shipped file> --ledger ledger.md` (for code, the final file can be a short summary of the change). Small mode is one review: no second round.

`cp done` also records every finding's fate for the project (outside the repo); the next review is shown the project's recent rejections so Codex stops re-raising them. `cp stats` shows how often each category of finding held up; `cp forget` clears it. `--no-repro` and `--no-memory` switch either off.

## Full mode: two plans judged blind, the better author writes, the other reviews

1. `cp plan --brief request.md --context AGENTS.md --bg`, then write your own plan to `plan-claude.md` **before** reading Codex's, so the two stay independent. Do not sign it or mention who wrote it. `cp wait`.
2. `cp compare --mine plan-claude.md --brief request.md --context AGENTS.md --bg`. Two blind judges score both plans on five criteria and list each plan's issues: Codex, and a fresh headless Claude session with no tools and no memory of your plan. The plans are shown as A and B in a random order. While they run, critique Codex's plan yourself. `cp wait` prints the unmasked judgments, the summed scores and the producer: Codex when its plan leads by 2 points per judge or more, you otherwise.
3. Merge the two plans into `merged.md`: start from the winning plan, fix the issues the judge and you found in it, take what the judge marked as worth keeping from the other. Settle every remaining divergence on the evidence (the constraint, the code, a quick check).
4. Produce, with the roles set by the comparison:
   - **You produce**: do the work, then `cp review ... --plan merged.md --bg` (Codex also flags plan steps that were skipped or wrong), work while it runs, `cp wait`, verify each finding, fix, `cp verify`, write the ledger.
   - **Codex produces**: `cp produce --brief request.md --plan merged.md [--write DIR]` (on a host without a Codex sandbox add `--allow-bypass`, which runs it unconfined). Then **you** review its output against the request, the context and the plan, run the tests, and fix what is wrong. Skip `cp review`: Claude reviewing Codex is the strong direction. If you have a concrete reason to write it yourself anyway (Codex cannot run what the task needs), produce and pass `--keep-producer "<why>"` to `cp done`.
5. When Codex's review had findings: `cp recheck --draft <revised file> | --diff --ledger ledger.md`. Codex resumes its review thread and confirms each fix and each rejection in seconds. Anything `unresolved` is a fix Codex says did not work: verify it, then fix it and recheck again, or change its ledger line to `rejected: <why>` if Codex is wrong. Add new `R` findings to the ledger. `cp done` refuses until the newest review has been rechecked and no disputed fix is still marked applied.
6. `cp done --final <file> --ledger ledger.md`.

## Closing the turn

- `cp done` refuses until every finding has a disposition, and refuses with no completed review (full mode: also no plan, no comparison, a producer other than the one chosen without `--keep-producer`, or fixes never rechecked). If Codex keeps failing, ship with `--unreviewed "<why>"` so the record says so; never present unreviewed work as reviewed.
- A turn with no deliverable (a question, a discussion): `cp skip "<reason>"`.
- With the toggle on, a Stop hook refuses the first stop of an armed turn that has neither; a second stop goes through and is logged in `~/.counterpoint/escapes.log`.
- End your answer with the one-line summary `cp done` prints, plus what the review changed (or "draft held").

## When Codex fails

`cp wait` or the foreground command prints `!!!` with the tail of Codex's stderr and exits 4. Re-run the same command once. Timeouts are bounded by `COUNTERPOINT_CODEX_TIMEOUT` (600 s).
