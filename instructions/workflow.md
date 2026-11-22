# Agent workflow

The primary session is the manager. It plans, briefs, verifies each worker itself, runs bounded local checks, and owns Git, tags, deploys, and the answer to the owner. It inspects each worker's diff and report before dependent work starts, dispatches no leads or sub-managers, manages the work, and does not investigate or debug itself; it fetches inputs workers cannot reach, such as CI logs and artifacts. It asks the owner only for decisions the owner must make, one question at a time, with a recommendation.

## Models and ownership

Routes (owner, 2026-11-22):

|Work|Role|GPT agent|Claude stand-in|
|-|-|-|-|
|Design, ADR, contract, or UI spec draft|`designer`|Sol|Opus|
|Design review|`reviewer`|Astra|Fable|
|Implementation, troubleshooting with its fix, and QA proofs|`implementer`|Terra|Sonnet|
|Code review and fix confirmation, including adversarial passes|`reviewer`|Sol|Opus|
|Searches, summaries, mechanical reading|-|-|`Explore` agent|

The primary writes documentation and prose itself, edits every design draft, and decides. Role rules are in [roles](roles.md); each brief names the role and points the worker there. A reviewer never runs on the author's model, and Astra and Fable never write code.

Dispatch each worker as a fresh `Agent` subagent with `subagent_type` `terra`, `sol`, or `astra` and no `model` override. These are the owner's user-level agents; each alias resolves to the newest model of its family, so plans and briefs name the family, never a model ID. The worker's first report line is its runtime model ID, which must belong to the named family. When a user-level agent cannot be dispatched, use the Codex plugin (`codex:codex-rescue` agent for work, `/codex:review` or `/codex:adversarial-review` for review) with `--model` set to the newest ID of the family; when GPT is unavailable, use the Claude stand-in with the `Agent` `model` `sonnet`, `opus`, or `fable`. Never fork for independent review: a fork inherits the parent model and context.

These agents have every tool, so a reviewer brief forbids edits, writing commands, and Git. The reviewer gets the code or design, the authorities, the diff, and the check output, never the author's conclusions. Resume the same reviewer with SendMessage to confirm fixes, and answer a worker's question with SendMessage to the same agent instead of starting a fresh one. Subagents each work in their own worktree and never change Git state or dispatch other agents. The owner chooses the primary session's model.

The owner approves product-visible choices before code starts.

## Flow

1. Read the brief's authorities and the domain's design docs and accepted ADRs. Design wins over a plan; an accepted ADR wins over conflicting design text.
2. For a contract or architecture change, the designer drafts the proposal from the primary's brief, the primary edits and decides, and the design reviewer reviews it before implementation. The designer revises and the reviewer confirms. Small changes skip design.
3. Brief one implementer per bounded task with exact paths. Write the failing regression test first, then the smallest correct change. Observe failure in CI or an approved local exception; otherwise report it as unrun. Adversarial cases for write safety, races, bounds, hostile input, authorization, and CSRF belong to the author.
4. Run the independent review once after the last code task. One-line changes, including production DNS, skip the reviewer pass; the primary shows plan or diff evidence instead under [ADR 0024](../docs/adr/0024-delivery-gates.md#amendment-one-line-review-exemption-2026-10-10). Local-only and test-only changes, and documentation or prose the primary wrote, also skip the fresh review under the delivery rules. Other security-relevant changes still require the adversarial pass before merge.
5. Return findings to the author for fixes, then request the original reviewer to confirm each fix on the same route.
6. The primary inspects each diff and report, runs `make pre-push` and approved bounded checks under the resource rules, and reads exact-commit CI evidence. It never repeats checks just to confirm a report. Before landing, read the local gate output for the exact head. On the owner fast path, a change to shared scripts, helpers, or test fixtures runs `make operational-test-fast` (or `make ci-local`) before push; a targeted test alone is not enough.
7. Push the branch. Do not open a pull request for the owner's work: a pull request starts hosted CI. Landing needs independent review where step 4 requires it and a passing [local gate](verification.md#local-gate) on the exact head. Finish and land one change before starting the next (owner, 2026-11-10).
8. The primary asks the Ubuntu host session to run the [local gate](verification.md#local-gate) on the exact head, reads its output, then merges with a signed `--no-ff` merge onto current `origin/main` and pushes `main` with the admin bypass on `main-required-ci`. Gate only commits the owner wrote or has reviewed, because the gate executes the checkout's scripts and pnpm lifecycle hooks with the owner's privileges; review changes to the Makefile, workflows, or dependency manifests before running them. For several ready branches, merge each head in order in a fresh worktree from `origin/main`, gate the combined head once, then push. Changes under `deploy/vn/` also dispatch `gh workflow run vn-infra.yml --ref <branch>`, because those tests need a hosted root runner. Contributors' pull requests land only after their `ci` check passed in a `pull_request` run; for those, a local merge of an up-to-date pull request whose checks passed is accepted. `main-required-ci` has an always-on bypass for the repository admin role; the separate `main-history` ruleset blocks force pushes and deletion without a bypass. A `workflow_dispatch` run never satisfies the ruleset ([GitHub](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks)). Every `main` push runs the full hosted gate; do not wait for it after landing, and check it before a tag under [releases](releases.md). Delete merged branches locally and remotely.
9. Close the GitHub notifications the work produced: review each thread for this repository (pull request, review, and failed-run threads), then mark it done with `gh api -X DELETE notifications/threads/<id>`. Close, never just mark read. A failed-run thread closes only after its cause is fixed or explained in the report.

## Reviews

Each independent review and fix confirmation follows the job's [route](#models-and-ownership) as a separate read-only job from the author. No agent reviews its own work. A worker's self-review never counts. A reviewer never implements what it reviews. The original reviewer confirms each fix on that route.

Security-relevant work beyond one-line changes needs an adversarial pass before merge: auth, sessions, CSRF, sanitizing, media privacy, publish revocation, credentials, keys, signing, production writes, deploys, and release workflows. Also check concurrency, idempotency, and migrations when touched. Name the invariants confirmed and trace each relevant attack end to end.

Model these attackers:

- An anonymous visitor to public resume pages and the API.
- A signed-in user attacking another user's resumes, media, or sessions.
- Hostile resume content (HTML, links, images, imports) reaching the renderer, link previews, print workers, or PDFs.
- A stolen session or MCP token.
- A network position between the visitor and the edge.
- A compromised container on the Vietnam host.
- A database writer without the application keys.
- A leaked backup.

Reviews stay read-only. Reviewers read the primary's check output and exact-commit CI runs; they never run local checks or delegate check execution. Evidence handling follows [documentation instructions](documentation.md#evidence).

## Concurrency and blocked workers

There is no numeric agent-job ceiling. Each concurrent writer has its own worktree. The primary creates worktrees, verifies their base commits, and coordinates shared fixtures. Managed local checks remain serialized under [resources](resources.md); ordinary commands need no mandatory wrapper or lock after the tooling change lands.

Implementing subagents run the brief's bounded checks through the managed lock under the resource rules. Read-only reviewers and explorers run none. The primary runs `make pre-push` before pushing and gives reviewers the check output.

When a worker stops with a question, a design conflict, overlapping ownership, or a missing decision, the primary answers from the reviewed design or returns the conflict to the designer and independent reviewer. Record an approved contract change in the design before resuming the worker with a new brief that states the answer. Never invent a contract.

When CI fails or a defect needs diagnosis, the primary downloads the failing logs and artifacts to the scratchpad and dispatches a troubleshooting subagent with that evidence. The worker follows [verification](verification.md#when-a-check-fails), finds the root cause, and fixes it; an independent reviewer reviews the fix. The worker reads the whole log and fixes every reported error together. Count red runs and their causes; two from the same cause, or a failure covered by `make pre-push`, means stop dispatching and repair the process before the next push. After two failed attempts, diagnose and rebrief instead of retrying unchanged work. Watch CI with a background wait that ends when the run completes and act on its result; never leave a landing half done.

## Lane instructions

Implementer rules, including lanes, shared files, and generated output, are in [roles](roles.md#implementer).

## QA and personas

QA writes scripted headless Playwright proofs, inspects display evidence, and
checks production releases. It never fixes product code. Follow
[testing](testing.md) for Playwright authoring and [web rules](web.md) for
display assertions, review images, and separate product images. The primary runs
or dispatches approved proofs; QA inspects the optional review images under
[display assertions](../docs/design/display-assertions.md); hosted Linux CI is
the display gate. Native HTTPS evidence stays partial and cannot replace Linux
CI.

Persona dogfooding reads `PRODUCT.md` and judges only the visible product at phone (390 px) and desktop (1440 px) widths. A Vietnamese job seeker signs up, starts from a template or sample, edits, publishes, shares, and exports in Vietnamese or English. Create accounts and resumes only on the local stack. In production stay signed out unless the brief names a test account; never use the owner's account or create, publish, or delete production resumes. A recruiter holds no account and stays signed out while reading public resumes, gallery samples, PDFs, and applicant tracking system text. Check content, order, credibility, and scan speed.

Persona evidence and defect reports follow [documentation instructions](documentation.md#evidence). Local proofs need an approved bounded primary-session command; the primary stops the stack when the proof ends.

## Reporting

Use [AGENTS.md](../AGENTS.md#briefs-and-reports) for briefs and exact file reports. Report checks run with results, checks not run with the exact command and reason, evidence paths, and open items. Never claim a failed or skipped check passed.

Review output: Verdict (`merge`, `fix first`, or `redesign`); Findings ordered blocker, major, minor; Checks read (CI runs and the primary's output); Not checked. Code findings use `R-nn. [severity] [category] file:line`; design findings use `S-nn. [severity] [category] file:line`; adversarial findings use `A-nn. [severity] [attacker] file:line`. Quote the code or text, state the failure scenario, and give one fix sentence. Mark an inference and cite its first-party source. Do not write the fix.
