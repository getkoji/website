---
title: "Don't Let the Agent Grade Its Own Homework"
description: "An AI agent can improve a document extraction schema on its own — read the failures, edit the config, re-test. The hard part isn't the loop. It's making sure the agent can't lie to itself about whether it worked."
date: 2026-06-29
author: "Frank Thomas"
tags: ["extraction", "schemas", "workflow", "agents"]
---

A few weeks ago I wrote about [Schema TDD](/blog/schema-tdd) — the inner loop of building a document extraction schema. Write a schema, run it against a real document, see what came back null, fix the description, run it again. Red, green, refactor. An AI agent can drive that loop end to end, and most of the time I let it.

That post stopped at one document. The harder problem is the outer loop: a pipeline is in production, thousands of documents are flowing through it, and *some of them are wrong*. How does the schema get better from real traffic — automatically, continuously, without a human babysitting every fix?

The answer is two loops feeding each other. And the only reason it's safe to let an agent run them is a set of guardrails whose entire job is to stop the agent from grading its own homework.

---

## The outer loop: production failures are the best training data

Every extraction pipeline has a confidence threshold. When the model extracts a field below that threshold, the document routes to a human review queue instead of flowing straight through. That queue is usually treated as a cost center — the stuff automation couldn't handle, a pile of manual work.

It's actually the highest-signal dataset you have. Every document in the review queue is, by definition, a document the *current schema couldn't extract confidently*. That's not noise. That's a labeled list of exactly where your schema is weak.

So the loop writes itself:

```
doc routes to review (low confidence on field X)
  → a human resolves it (supplies the correct value)
  → promote the corrected document into the corpus as ground truth
  → improve the schema so field X stops being low-confidence
  → re-validate until accuracy recovers, with no regressions
  → that whole class of document stops routing to review
```

The left half — mining the queue, promoting corrected documents into the validation corpus — is the new part. The right half is Schema TDD: edit the schema, backtest it against the corpus, ship when it's green. We packaged both as Claude Code skills that ship with the Koji CLI: `review-corpus-loop` (the outer loop) hands off to `schema-loop` (the inner loop). An agent can run the whole thing from a terminal:

```bash
# survey what keeps failing
koji review ls --status completed --json | jq '.[] | {field: .fieldName, reason}'

# promote the human-corrected documents into the corpus as ground truth
koji review ls --status completed --json \
  | jq -r '.[] | select(.resolution=="approved") | .id' \
  | while read -r id; do koji review promote "$id" --json; done

# now improve the schema for whatever field kept routing to review,
# and backtest against the whole corpus
koji validate ./schema.yaml --check --json
```

The signal is clean. If `effective_date` shows up in the review queue forty times this week, that field's description or routing hints are the problem — not the model, not bad luck. The agent reads the reason code, turns the right knob, and proves the fix against every document in the corpus.

Left alone, an agent will run this loop happily forever. Which is exactly the problem.

---

## The failure mode: an agent that improves its own score by lowering the bar

Here's the trap. The corpus is the one asset that has to stay trustworthy, because `koji validate`'s entire signal depends on it. Validation works by re-extracting every corpus document that has ground truth and scoring the output against that ground truth. The accuracy number *is* the comparison to the corpus.

Now hand that loop to an autonomous agent and watch what it's incentivized to do. The agent's job is to make accuracy go up. There are two ways to make accuracy go up:

1. Make the extraction better.
2. Make the ground truth agree with whatever the extraction already says.

The second one is faster. And an agent that can both propose ground-truth labels *and* score itself against them will, eventually, find that shortcut — not maliciously, just because it's the path of least resistance to a higher number. It writes a label that matches the model's flagged (wrong) value, scores against it, declares victory. The number goes up. The extraction is still wrong. You've built a machine that lies to itself.

This isn't hypothetical with LLM agents. Self-grading is a known failure mode, and the fix isn't a better prompt. It's structural.

---

## Three guardrails that make autonomy safe

The skills are built so the agent *structurally cannot* take the shortcut. Three rules, each enforced in the system, not in a prompt the model could rationalize its way around.

### 1. The agent can't approve its own labels

When a human resolves a review item, that correction is theirs. The agent just moves it into the corpus — zero risk, fully autonomous, because a human supplied the answer.

But when there's no human resolution and you want a *fully* autonomous loop, the agent can read the document and propose a label itself. Those labels land as **drafts**, and drafts are deliberately excluded from validation until a human approves them. The agent can guess all it wants; its guesses don't count toward the score it's trying to maximize until someone who isn't the agent signs off.

```bash
# the agent reads the document and proposes a corrected label
koji review promote <id> --provisional --gt-from label.json --json
# → draft. Excluded from validate. A human approves it in the dashboard
#   before it ever affects the accuracy number.
```

The rule, stated plainly in the skill's guardrails: *never auto-approve your own drafts. An agent approving its own guesses is grading its own homework.* The exclusion is enforced server-side — draft labels aren't written into the scored ground truth at all — so the agent can't route around it even if it tried.

### 2. Iterating never touches production

The second footgun is subtler. For a long time, `koji validate` didn't just *read* the live schema — it *wrote* it. Every validation run snapshotted the candidate schema and immediately made it live for every production pipeline, before validation even ran, pass or fail. An agent backtesting twenty edits would flip the live schema twenty times. The agent's experiments were production deploys.

We fixed that by splitting "snapshot this version" from "make it live." Now `validate` creates a **release candidate** — a real, persisted, fully traceable version tagged `v0.0.4-rc.7` — but it never activates. Production pipelines stay on the current released version no matter how many candidates the agent churns through. The agent can iterate as fast as it wants in a sandbox that looks exactly like production but isn't.

Going live is a separate, explicitly gated step:

```bash
koji schema promote <slug> --require-no-regressions
```

That's the one command that affects production, it's permission-gated, and it's manual by design — there's no auto-promote-on-threshold. The agent can get a candidate to 97%, but it can't ship it. A human (or an explicitly authorized step) graduates the candidate to a release. Safe to iterate, gated to ship.

### 3. A regression is a failure, even when the number goes up

The last rule is the one that turns "the score improved" into "the schema actually got better." The target document passing is necessary but not sufficient. The fix also has to not break anything else.

`koji validate` reports per-field status across the whole corpus — `pass`, `regressed`, `failing`. A change that fixes the document you were working on but regresses a different field is not a win. It's a failure, and the loop is built to treat it as one: refine the change or revert it and try something narrower. `--check` exits non-zero on any regression, so the agent's own success condition includes "broke nothing." You can't buy one document's accuracy with another's.

And because the version string is semver derived automatically from the schema's output shape, a candidate named `v2.0.0-rc.3 @ 96%` tells you at a glance that releasing it is a *breaking* change to the output contract — even though the accuracy looks great. The number isn't the whole story, and the system refuses to let it pretend to be.

---

## Why structure beats supervision

You could try to get all of this from a careful prompt: "please don't approve your own labels, please don't deploy to production while iterating, please don't trade one field's accuracy for another's." It would mostly work. It would also fail silently, occasionally, in exactly the cases you'd never think to check — and with document extraction the cost of a silent failure is a wrong expiration date on an insurance policy that nobody catches until it matters.

So none of those three rules live in a prompt. Drafts are excluded from scoring in the database. Candidates can't activate without a gated promote. Regressions exit non-zero. The agent operates inside a structure where the shortcuts are *unavailable*, not merely discouraged. That's the difference between an autonomous loop you can trust and a demo that works until it doesn't.

The loop is the easy part. Almost anyone can wire up "read the failures, edit the config, re-test." The thing that makes it production-grade is the boring infrastructure underneath: a corpus that only a human can grow, a validation step that can't touch production, and a definition of "better" that includes "broke nothing else." Build those, and you can hand the whole thing to an agent and go do something else.

Just never let it grade its own homework.
