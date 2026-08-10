---
name: counterpoint
description: Run one turn through a bounded producer-critic loop across two flagship models (Claude Opus as orchestrator, OpenAI Codex via `codex exec` on the ChatGPT subscription). Two depths: small (cross-criticism only) and full (joint planning front-end added before production). Invoke for a single task where a second, model-diverse critic should catch blind spots before shipping: code with tests, or prose/research checked against a brief and AGENTS.md.
---

# counterpoint

You (Opus) are the orchestrator. For this one turn you run a fixed, bounded
producer-critic exchange instead of answering directly, then ship the revised
result. The exchange runs once through its choreography. Small mode is strictly
linear and never loops. The only step that may repeat is the capped mini-loop in
step 6, which is full mode only and only when a hard verifier exists.

The second model is reached through the bundled helper:
`<skill_dir>/scripts/codex-consult.sh`. It runs one read-only Codex pass on the
ChatGPT subscription, reads the assembled prompt from stdin, and prints only
Codex's final message on stdout. Resolve `<skill_dir>` to this skill's own
directory before calling it. Each call is a multi-minute turn; that cost is the
point of the loop and the reason it is opt-in. The helper disables user-config
MCP servers and re-injects the configured Codex model, so a read-only critic
cannot spend the turn calling web tools under a networkless sandbox.

## Mode selection

Read the first token of what the user passed after `/counterpoint`:

- `full` -> run **full mode**: do the joint planning front-end (steps F1 to F3)
  first, then the shared pipeline. The rest of the line is the task.
- `small` or no mode token -> run **small mode**: skip straight to the shared
  pipeline. The whole line (or the part after `small`) is the task.

If nothing was passed, the task is the current request. `off` is plain
single-model Claude Code, so in that case the skill is simply not invoked.

Pick **full** for high-stakes turns where starting from a bad plan is expensive
(architecture, a long document, a multi-step refactor). Pick **small** for an
ordinary turn where one cross-critique pass is enough.

Small mode is strictly linear and never loops: Opus produces one draft, Codex
critiques it once, Opus revises once and finalizes. There is no second critique
and no mini-loop, even for code with a hard verifier: the verifier runs once, its
result is surfaced, and the turn ships. Iteration lives in full mode. This bound
is enforced, not just described: `counterpoint-run.sh` refuses a second critique
run in small mode (see enforcement below).

## Step 0, resolve the shared context (the parity contract)

Gather, once, the context both roles will share:

1. the original user request, verbatim;
2. every resource that request pulls in: if it says read AGENTS.md, read that
   AGENTS.md; the same for the active skill and any named file. Resolve and keep
   the actual text, so it can be inlined into the Codex calls later;
3. (added later) the producer's plan, then the producer's full output.

The critic checks adherence to these documents, so it has to hold the same ones
the producer held. A constraint it never read is a constraint it cannot check.

## The Karpathy scaffold

Four task-agnostic working rules ride in every producer prompt and every critic
prompt, for both models, so drafting and evaluation are held to one standard
whatever the task (code, prose, research, marketing):

1. **Think before producing.** Reason about the task, the constraints, and the
   failure modes before drafting. Start only when the approach is clear.
2. **Simplicity first.** Prefer the simplest solution that meets the stated
   constraints. Add no unrequested feature, abstraction, or scope.
3. **Surgical changes.** Make the minimal targeted change. Leave unrelated code
   and text untouched. No drive-by refactors.
4. **Goal-driven.** Keep the deliverable in view. Let every step serve the stated
   goal.

The four rules above are a readable summary. The operational source is the file
`<skill_dir>/prompts/karpathy-scaffold.txt`, and every injection uses that file's
literal contents, so there is one copy to maintain. The three enforced scripts
(`counterpoint-plan.sh`, `counterpoint-run.sh`, `counterpoint-review.sh`) read the
file and inject it into every out-of-session Codex prompt, so the plan (F1), the
critique (step 3), and the plan review (F3) all carry it. For its own in-session
passes and for the Codex produce prompt it assembles by hand, Opus resolves the
same file and prepends its literal contents verbatim, with a one-line role
framing: a producer follows the scaffold while drafting, a critic applies it as a
standard for the work under review and a discipline for its own critique.

## Full mode front-end (full mode only)

In small mode, skip this whole section and go to step 1.

### Step F1, joint plan (run through `counterpoint-plan.sh`)

Both models draft a plan against the step 0 context. Neither implements or writes
the deliverable yet. So the joint plan is enforced rather than narrated, run it
through the command instead of piping to Codex by hand:

1. Opus writes its own concise plan (steps, key decisions, risks, edge cases) to
   a file, following the Karpathy scaffold. Do this first, before Codex's plan is
   fetched, so the two plans stay independent. (`counterpoint-plan.sh` injects the
   same scaffold into Codex's planning prompt, so both plans are drafted to it.)
2. Call `scripts/counterpoint-plan.sh --task "<short>" --prompt <prompt-file>
   --opus-plan <opus-plan-file> --resource <each resolved AGENTS.md/skill/file>
   [--code]`. It re-resolves the parity context from source, fetches Codex's plan
   read-only via `codex-consult.sh`, records both plans under
   `~/.counterpoint/runs/<ts>/`, and prints Codex's plan on stdout. The `Stop`
   hook requires this plan artifact in full mode, so the front-end cannot be
   silently skipped.

**Prefer the split form**, which removes the Codex plan latency from the turn
entirely. Launch first, draft while it runs, then collect:

```
scripts/counterpoint-plan.sh --launch --task "<short>" --prompt <prompt-file> \
  --resource <each resource> [--code]        # prints the run dir, returns at once
<write Opus's plan to a file>
scripts/counterpoint-plan.sh --collect --run <run-dir> --opus-plan <opus-plan-file>
```

Independence still holds by construction rather than by ordering: the planning
prompt is assembled from the request and the resources only, so Codex never sees
Opus's plan, and Codex's answer stays in a hidden pending file that only
`--collect` promotes, so there is nothing for Opus to read early. Do not cat
`.plan_codex.pending` by hand; that is the one move that would break it.

### Step F2, score both plans, then assign the producer

This is the defined arbitration step, and it is decided on one thing only: plan
quality. The producer is the author of the higher-scoring plan; a genuine tie
goes to Opus. There is **no capability carve-out and no forced quota**. The aim
is **equal opportunity**: Codex's plan wins production whenever it is the better
plan, so across turns production is not pinned to one model. The two roles are
exclusive per loop: whoever produces does the whole task, and the other model is
the reviewer/critic. A model is never both producer and reviewer in the same
loop.

**Part 1, score both plans (Opus scores).** Label the plans "Plan A" and "Plan
B". Opus scores each plan on the five criteria, 0 to 2 per criterion (max 10),
with one cited line from the plan per cell, so padding (naming files that do not
matter, a clever-sounding aside) is visible and scores 1 not 2:

| # | Criterion | 0 | 1 | 2 |
|---|-----------|---|---|---|
| 1 | **Constraint coverage**: every hard constraint from the brief, AGENTS.md, and the active skill is mapped to a step | misses or contradicts one | covers most | all mapped to a step |
| 2 | **Critical-path correctness**: following the core steps yields a correct deliverable; no load-bearing assumption is wrong | a key step is wrong | one shaky step | correct throughout |
| 3 | **Load-bearing specificity**: names the files, sections, or steps that actually reduce execution risk, not decorative naming | vague | partly concrete | concrete where it matters |
| 4 | **Off-path risk handling** (distinct from 2, which is the happy path): anticipates what breaks off the happy path and pre-empts it | none named | the obvious ones | the non-obvious ones too, with mitigations |
| 5 | **Decision-level information gain**: a choice that changes the outcome (a better decomposition, a sharper constraint), not a clever-sounding aside | generic plan | one real improvement | a materially better frame |

The rubric scores plan quality, not task domain, so it applies the same way to
code, prose, research, and marketing.

Opus scores alone, and it is an interested party (it wrote one of the plans), so
it carries a known self-preference lean of about a point. That lean is expressed
**once**, inside the cell scores: when Opus is genuinely torn on a criterion for
Codex's plan, it may land on the lower value for that cell. Once the five cells
are totaled, the totals are final and decide the producer directly (Part 2). The
lean is never re-applied to the totals afterward. A one-point gap is a real lead
that the tie rule does not touch, and re-reading such a gap as a tolerance band
("close enough, call it a tie") counts the lean twice: that is the exact bug this
rule forbids. The lean is accepted at the cell level rather than corrected because
the target is equal opportunity: a clearly better Codex plan wins by more than a
one-cell lean, and a genuine dead heat already goes to Opus (Part 2), so the only
cases the lean touches are the ones the tiebreak resolves the same way. (An
earlier design had both models score both plans blind and averaged the totals to
cancel the lean; it was dropped as cost that buys only the margin.)

**Part 2, decide the producer from the totals.** The totals as scored are
authoritative. Two conditions, nothing else:

- **Higher total produces**, the other reviews and critiques. Any margin counts:
  a 10 to 9 result routes production to the author of the 10. There is no
  tolerance band around the tie, so a one-point lead already wins production
  outright.
- **Exact tie -> Opus produces.** Only equal totals are a tie. On a dead heat the
  turn stays on the live, in-session process: Opus is already the finalizer
  (Config A), so a tie keeps production and finalization on one process. It is an
  honest routing default that happens to save a split, and its purpose is routing
  rather than bias correction.

**Codex's read-only status in planning and critique does not constrain
production.** Read-only is the *critic's* sandbox (`codex-consult.sh` runs
`-s read-only`), chosen because a critic only needs to read. It says nothing
about what Codex can do when it holds the producer role. When Codex wins the
score it produces the **whole** deliverable through `scripts/codex-produce.sh
--write <scratch>` with full authorizations, file writes, network, and
credentials, exactly like Opus would. On a gVisor-style host set
`COUNTERPOINT_CODEX_BYPASS_SANDBOX=1` so the write path uses
`--dangerously-bypass-approvals-and-sandbox` instead of the bubblewrap sandbox
that fails there. There is no per-task carve-out and no fetch-then-analyze split:
the producer is the producer, agnostically, for code, prose, research, or a
live-data audit. The one fixed invariant is that **Opus finalizes**: even when
Codex produces, Opus does the last review in session before delivery, so the
ship keeps one coherent voice.

**Part 3, reconcile the plans.** Independently of who produces, merge the two
plans into one agreed plan: where they agree is safe; where they diverge is the
audit signal, so settle each divergence on the verification ladder (step 4
logic). Both models then follow this one agreed plan.

### Step F3, review the reconciled plan before producing

Reconciliation (F2 part 3) merges the two independent plans into one agreed plan,
and that merge is the live Opus's own work: it can introduce an option neither
original plan carried and that no one has checked yet, a merged step, a gap filled
in the seam between the two plans. So before production, the **reviewer (the
non-producer) reviews the reconciled plan** against the step 0 context and reports
located problems the same way it critiques a draft: which merged step is
unsupported, which constraint the merge dropped, which invented option has no
backing. Then the **producer arbitrates that plan review** (the literal prompt is
*"what do you think of this plan review?"*): for each point, keep or reject it
with a reason, and fold the kept points into the agreed plan. Only then does
production start. This is the safety net for reconciliation-invented content, so
the agreed plan is read by both models before it is built, not just before it is
written.

Run this through the command so F3 is enforced, not narrated. Write the reconciled
agreed plan to a file, then call `scripts/counterpoint-review.sh --task "<short>"
--plan <agreed-plan-file> --prompt <prompt-file> --reviewer <opus|codex>
--producer <opus|codex> --resource <each resource> [--code]`. It re-resolves the
parity context from source, injects the Karpathy scaffold (critic framing) into
the Codex review prompt, and writes the per-turn plan-review artifact
(`plan_review.txt`); the `Stop` hook requires it in full mode, so F3 cannot be
silently skipped. The command is role-aware, on the one unified rule (a real Codex
call is hard and must leave an artifact; an Opus-in-session pass has nothing to
force):

- **Reviewer is Codex** (Opus produced): a real out-of-session Codex call. The
  command runs the read-only Codex plan review; `plan_review.txt` holds it. Opus
  (the producer) arbitrates inline. This is the hard case.
- **Reviewer is Opus** (Codex produced): the live session Opus reviews the plan
  in-session; the command makes no Codex call and records the in-session review
  and the roles in `plan_review.txt`. Codex (the producer) arbitrates via the
  produce prompt. Soft, but still recorded so the phase provably ran.

Record the two score matrices, the totals, the producer decision, the agreed
plan, and the plan-review outcome, then skip step 1 (roles are assigned) and go
to step 2.

## Step 1, assign the roles (small mode)

Small mode has no planning front-end, so there are no two plans to score. The
producer arbitration by plan scoring lives in full mode (step F2). Small mode is
the deliberate fast lane, so it uses the structural default:

- **Opus produces.** Opus is the live, in-session process: it can run the tools,
  edit files, and run the hard verifier. With no plan to arbitrate on, the
  live-session advantage is the only signal, so Opus authors the one draft. Small
  mode does not iterate: it is one produce, one critique, one revise, then ship.
- **Codex critiques.** Codex is the fresh, independent pass from another lab,
  reached read-only through `codex-consult.sh` (plus `codex exec review` on code).
- **The live Opus finalizes** (Config A), so the ship keeps one coherent voice.

If you want the producer arbitrated by plan quality (Codex able to author when
its plan scores higher), run **full mode**: the plan-scoring step (F2) is where
that decision is made. Record the roles in the role log (step 8).

Whether a hard verifier exists (tests, build, types for code; none for prose,
research, marketing) is a property of the deliverable, not of the producer
choice. In small mode the verifier runs once and its result is surfaced, but it
never opens a mini-loop: small ships after the single revise pass regardless. The
capped mini-loop in step 6 is full mode only.

## Step 2, produce

The producer writes the draft against the full context from step 0 (and, in full
mode, the agreed plan from step F2), following the Karpathy scaffold. The three
enforced scripts inject the scaffold themselves, but the produce prompt is
hand-assembled, so the producer adds it here.

- Producer is Opus: draft inline against the scaffold.
- Producer is Codex: assemble the produce prompt (the scaffold with producer
  framing, then the request plus the inlined resources, plus the agreed plan in
  full mode) and run it through `scripts/codex-produce.sh`. When the deliverable is just characters Opus can
  place, the default text-emission mode returns the draft on stdout and disables
  user-config MCP servers, same as the critic helper. When the task has to write
  files, run tools, hit the network, or use credentials (a
  multi-file change, a live-data audit), pass `--write <scratchdir>` so Codex
  holds real authorizations for its producer call; on a gVisor-style host also
  set `COUNTERPOINT_CODEX_BYPASS_SANDBOX=1`. Do not produce through
  `codex-consult.sh`: that is the read-only critic helper and cannot write or
  act.

## Step 3, critique with full context parity

Assemble a single critique prompt containing, in this order:

1. the original request, verbatim;
2. the inlined resolved resources from step 0 (the real AGENTS.md / skill /
   file text, fully resolved and inlined);
3. in full mode, the agreed plan from step F2;
4. the producer's full draft;
5. the Karpathy scaffold (critic framing), then the instruction: produce a
   checklist verdict (PASS or FAIL with a one-line reason) against each stated
   constraint from the brief, AGENTS.md, and the active skill, then list located
   problems (this sentence, this claim, this function) with suggested fixes. Do
   not rewrite the draft. (`counterpoint-run.sh` injects the scaffold for you; add
   it by hand only when you critique in session.)

Run the critic:

- Critic is Codex: pipe the assembled prompt to `codex-consult.sh`. For a code
  task, also run `codex exec review` in the repo for a second, model-diverse
  pass over the diff.
- Critic is Opus: critique inline against the same assembled context.

## Step 4, settle disagreements on the verification ladder

Use the highest rung available (see eng/03). For every flagged issue:

1. **Hard verifier (code only).** Run the tests, the build, the type checker,
   the linter. A flagged issue that breaks one of these must be fixed; the
   orchestrator's opinion does not override a failing check.
2. **Constraint-adherence (universal).** Does the draft satisfy each written
   constraint in the brief, AGENTS.md, and the skill? A flagged violation of a
   written constraint must be fixed.
3. **Reasoned critique (fallback).** A taste-only issue goes to the finalizer's
   judgment, which must cite a specific reason. Minimize reliance on this rung.

Record which rung settled each disagreement (step 8).

## Step 5, revise

The producer applies the required fixes from step 4. Taste-only items are
applied at the finalizer's discretion.

## Step 6, capped mini-loop (full mode only, and only when a hard verifier exists)

**Small mode skips this step entirely: it is strictly single-pass and never
loops.** One produce, one critique, one revise, then ship, even for code with a
hard verifier. `counterpoint-run.sh` enforces this by refusing a second critique
run in small mode.

In **full mode**, for code with tests/build/types, one revision may not pass. In
that case only:

```
re-run the verifier
  passes?  yes -> go to step 7
           no  -> one more produce-critique-revise round
hard cap at 2-3 total rounds
still failing at the cap -> stop, ship with the failure surfaced, do not loop forever
```

Everywhere there is no hard verifier (prose, research, marketing) there is no
objective stop, so a single defined pass is the rule and this step is skipped.

## Step 7, deliver

The finalizer ships the revised result. For prose, the author finalizes so the
output keeps one coherent voice. For code, the model that produced the cleaner
passing version finalizes.

Then record the shipped deliverable in the run artifact so the enforced set holds
the revised content, not just the pre-revision draft: write the final to a file
and run `scripts/counterpoint-finalize.sh --final <revised-file> --caught "<what
the critique changed, or 'nothing, draft held'>" [--plan-review "<full mode: what
the reviewer flagged and what the producer kept>"]`. It writes `result.md` (the
shipped deliverable) into this turn's run dir and resolves the `caught:` and (full
mode) `plan review:` lines of the role log. The `Stop` hook requires `result.md`,
so the deliver phase provably ran.

## Step 8, role log

End the turn with a short block so we can see how the loop behaved:

```
counterpoint (<small|full>): producer=<model> critic=<model> finalizer=<model>
plan score: <full mode: planA <n>/10 vs planB <n>/10 (opus-scored) -> producer=<model> (<higher | tie -> opus>); small: n/a>
plan delta: <full mode: one line on what the two plans disagreed on and how it settled; small: n/a>
plan review: <full mode: one line on what the critic flagged in the reconciled plan and what the producer kept (step F3); small: n/a>
arbiter rung: <hard-verifier | constraint-adherence | reasoned-critique>
mini-loop rounds: <full mode: n; small: n/a (single-pass, never loops)>
caught: <one line on what the critique changed, or "nothing, draft held">
```

## Enforcement (v2): run the audited half through the command

The steps above are the choreography. So that the loop is enforced rather than
just narrated, run the audited half through `scripts/counterpoint-run.sh` instead
of assembling the critique prompt by hand: save the producer's draft to a file,
then call

```
scripts/counterpoint-run.sh --mode <small|full> --task "<short>" \
  --draft <draft-file> --prompt <prompt-file> \
  --producer <opus|codex> --critic <opus|codex> --finalizer <opus|codex> \
  --resource <each resolved AGENTS.md/skill/file> \
  [--plan <agreed-plan-file>] [--code] [--verifier "<cmd>"]
```

Pass the roles: `--critic` decides who audits, and it must be the non-producer.
The command re-resolves context parity from source (it reads the files, so parity
is guaranteed), then routes the critique by role. When Opus produced
(`--critic codex`) it runs the read-only Codex critique via `codex-consult.sh`
(and `codex exec review` on code). When Codex produced (`--critic opus`) it runs
NO Codex call: it resolves the parity context into `context.txt` and you (the live
Opus) critique it in-session, because shelling to Codex there would be Codex
reviewing its own draft and would lose the cross-model point. It then runs the
hard verifier when one exists and writes the per-turn run artifact under
`~/.counterpoint/runs/<ts>/` (the audited draft as `draft.md` plus `log.txt`).
Revise from the critique, then finalize with `scripts/counterpoint-finalize.sh
--final <revised-file> --caught "<one line>"`, which writes `result.md` (the
shipped, revised deliverable) and resolves the role log. A `Stop` hook
(`hooks/counterpoint-stop-hook.sh`) refuses to end the turn until both the run
artifact (`log.txt`, carrying the `ok` marker and a non-empty critique) and a
non-empty `result.md` exist, so neither the critique nor the revision can be
silently skipped, and a Codex call that failed cannot pass for one that ran. The `--verifier` command is judged by its exit code, so do not mask it
behind a pipe (e.g. `... | tail`), or a failing check will read as a pass. When
Codex holds the producer role, use `scripts/codex-produce.sh` (text emission, or
`--write DIR` for heavy multi-file production). Full design: `eng/07`.

In **full mode** three phases are enforced, on one unified rule: **every point
where an out-of-session Codex call is required must leave a per-turn artifact, so
the `Stop` hook can prove it ran; an Opus-in-session pass has nothing to force,
since Opus is the live session and cannot fake presence.** The three enforced
artifacts are the joint plan (F1), the reconciled-plan review (F3), and the
critique (step 3):

1. **F1, joint plan.** Before producing, write Opus's plan to a file, then run
   `scripts/counterpoint-plan.sh --task "<short>" --prompt <prompt-file>
   --opus-plan <opus-plan-file> --resource <each resource> [--code]`. It records
   both plans (`plan_codex.txt`) under `~/.counterpoint/runs/<ts>/`. Codex always
   plans in full mode, so this is always a hard Codex call.
2. **F2, score and assign** (in-session, soft). Score both plans on the rubric
   (Opus scores both inline, one cited line per cell) and let the higher plan's
   author produce (a genuine tie goes to Opus). Producer is decided on plan score
   alone; when Codex wins it produces the whole task through `codex-produce.sh
   --write`, so nothing about its read-only critic sandbox keeps production on
   Opus. Reconcile the two plans into one agreed plan.
3. **F3, review the reconciled plan.** Write the agreed plan to a file, then run
   `scripts/counterpoint-review.sh --task "<short>" --plan <agreed-plan-file>
   --prompt <prompt-file> --reviewer <opus|codex> --producer <opus|codex>
   --resource <each resource> [--code]`. It writes `plan_review.txt`. Reviewer is
   Codex (Opus produced): a real read-only Codex review, the hard case. Reviewer
   is Opus (Codex produced): in-session, no Codex call, recorded so the phase
   provably ran. The producer then arbitrates the review and folds kept points
   into the agreed plan.
4. **Produce, then critique, then finalize.** When Codex is the producer, use
   `scripts/codex-produce.sh`; either way run `counterpoint-run.sh` for the
   critique half (critic = the non-producer). In full mode pass the agreed plan
   with `--plan <agreed-plan-file>` so the critic checks the draft against it.
   Opus finalizes in session, then records the shipped deliverable with
   `counterpoint-finalize.sh` (writes `result.md`).

The `Stop` hook refuses to end a full-mode turn until all four artifacts
(`plan_codex.txt`, `plan_review.txt`, `log.txt`, and the finalized `result.md`)
exist for the turn AND each Codex-backed phase carries its `ok` marker, so no
phase can be silently skipped and none can be satisfied by a failed call.

## When a Codex call fails

Every out-of-session Codex call is bounded and every phase records whether it
actually produced something usable. A phase that timed out or came back empty
writes its artifact for debugging but no `ok` marker, and the `Stop` hook keys
off that marker, so a failed call cannot pass for a completed phase. Three
consequences worth knowing:

- The command tells you on stdout, in a block starting `!!!`. Read it. Shipping
  after a failed critique means shipping unaudited work while the role log claims
  otherwise.
- A failed critique does **not** consume a mini-loop round, so re-running the
  same command is the correct response, including in small mode. The single-pass
  bound counts audits, not attempts.
- `counterpoint-finalize.sh` refuses to attach `result.md` to a failed run, so a
  turn cannot be closed on one.

Diagnose from the `.stderr` file beside the artifact (`critique.stderr`,
`plan_codex.stderr`, `plan_review.stderr`, `code_review.stderr`).

## Operational tuning

Defaults are set for a normal turn; these exist for hosts and tasks that are not.

| Variable | Default | What it does |
|---|---|---|
| `COUNTERPOINT_CODEX_TIMEOUT` | `600` | Hard bound per Codex attempt, in seconds. `0` disables it, which is how the loop used to behave: one recorded run then spent nine minutes in a hung tool loop and returned nothing. |
| `COUNTERPOINT_CODEX_RETRIES` | `1` | Extra attempts after a non-timeout failure. A timeout is never retried: a stuck run stays stuck and would just spend the bound twice. |
| `COUNTERPOINT_PLAN_EFFORT` | `high` | Reasoning-effort **cap** for F1. |
| `COUNTERPOINT_REVIEW_EFFORT` | `high` | Reasoning-effort cap for F3. |
| `COUNTERPOINT_CRITIQUE_EFFORT` | (config) | Reasoning-effort cap for the critique and the code review. Unset means the configured effort. |
| `COUNTERPOINT_RETENTION_DAYS` | `30` | Run-dir retention. `0` keeps everything. |
| `COUNTERPOINT_TURN_ID` | (hook) | Turn attribution when running outside Claude Code, where no `current-turn` stamp exists. |
| `COUNTERPOINT_CODEX_BYPASS_SANDBOX` | `0` | Set to `1` on a gVisor-style host, where Codex's bubblewrap sandbox cannot start. It covers the producer write path and `codex exec review`; without it the code review exits 0 while reporting it could not inspect the diff. |

The effort settings are caps, never settings: they lower the configured effort
for the cheaper phases and never raise it, so running the whole loop at `medium`
stays at `medium` throughout. Planning and reading a merged plan do not need the
budget an audit of a finished deliverable needs, and running every phase at the
top of the scale was the single largest latency term in a turn.

## Scope of this MVP

Small and full modes. Two invocation paths: the manual `/counterpoint` slash
command, and the always-on toggle, where a `UserPromptSubmit` hook
(`hooks/counterpoint-hook.sh`) reads `~/.counterpoint/mode` and runs this skill
at the selected depth on every turn. The v2 enforcement command and `Stop` hook
above are built. Note the enforcement is per-turn by design: with the toggle on,
the `Stop` hook refuses to end *any* turn until a matching run artifact exists,
including a pure advisory or design turn that produces no deliverable, which then
spends Codex round-trips on nothing. So the always-on toggle is for a working
session where each turn is an actual task; during design or advisory
conversation, keep the toggle `off` and invoke `/counterpoint full` by hand on
the turns that warrant it. A reliable "is this a task turn" detector is unsolved
and deliberately not attempted here. The CLI (bundled scripts plus `counterpoint-run.sh`) is the
chosen surface; an MCP wrapper was considered and dropped, since the CLI plus the
`Stop` hook already enforces the loop. Supported on Linux and macOS with one
shared codebase. Each turn makes one or more CLI calls to Codex on the ChatGPT
subscription, so expect a multi-minute turn, and more in full mode because of the
extra planning pass. Three things keep that from growing without bound: the plan
call overlaps Opus's own drafting (`--launch`/`--collect`), the code review runs
alongside the critique rather than after it, and the two plan phases are capped
at a lower reasoning effort than the critique.
