---
title: "Auto-tune: Letting the Agent Fix the Schema, From the Dashboard"
description: "Koji's schema build page can now tune a schema on its own: score it against every labeled document, have a model propose a fix, re-score, and keep the change only if nothing got worse. Here's how the loop works, what keeps it honest, and why runs are built to survive a closed tab."
date: 2026-08-13
author: "Frank Thomas"
tags: ["extraction", "schemas", "agents", "workflow"]
---

In [Don't Let the Agent Grade Its Own Homework](/blog/agent-grades-own-homework) I described the schema-improvement loop an agent runs from a terminal, and the guardrails that make it safe: agent-drafted labels don't count toward the score, validating never touches production, and a regression is a failure.

Auto-tune is that loop in the schema build page: one button, and the schema improves against your labeled documents. Here's how it works, how it avoids overfitting (and where it doesn't), and what we got wrong first.

---

## What it does

Open a schema's build page, go to the **Agent** tab, and switch from **Chat** to **Auto-tune**. Press **Auto-tune this schema** and a run starts against every corpus document for that schema that has ground truth.

A run is a loop of rounds:

1. **Score the current schema across the corpus.** Every labeled document goes through the build page's parse and extraction path, and the output is compared to ground truth field by field using the same scoring function as validation.
2. **Pick something to fix.** Among the fields that fail, take the one with the lowest corpus-wide accuracy. Then take a document where that field fails, and collect every field that fails on that document.
3. **Diagnose each failure.** For each failing field the scorer checks whether the correct value appeared in the text routed to that field. If not, it's a routing miss. If so, the model saw the answer and picked wrong, which is a wording problem. The tuner is told which one it's looking at.
4. **Ask the model for a minimal edit.** The prompt contains the current schema, the expected and extracted values for each failing field with its diagnosis, an excerpt from the focus document, and the proposals already rejected in this run. The model returns a complete schema; if it doesn't compile, the tuner retries once with the compiler errors, then discards it.
5. **Re-score the whole corpus with the proposed schema** and decide whether to keep it.

The run stops when every labeled field passes, when three rounds in a row fail to raise accuracy, or when it reaches the round limit (five by default, eight at most).

The panel shows baseline and best accuracy, and for each round: the focus document, the fields targeted, any regressions, whether the change was kept, and the model's reasoning.

## The first version optimized the wrong thing

The first autonomous loop shipped with a target of one document. You picked a labeled document and the loop tuned the schema until that document passed. Checking the rest of the corpus was a separate step at the end.

That overfits. A fix that gets one document to 100% can be narrow enough to break five others, and the loop gets no signal about it until the end. The final check catches the damage, but every round was spent optimizing toward it.

So the target changed. The objective is now **corpus accuracy**, and a failing document only decides what the next edit should try. That's how I tune by hand: use one broken document to work out what's wrong, judge the fix on everything. The single-document tab is gone from the dashboard; its endpoint (`tune/loop`) remains in the API.

## The acceptance rule

A proposal is kept only when both of these hold:

- corpus accuracy is **at least** as high as the best schema so far, and
- **no field regressed.** A field regresses when its corpus-wide accuracy under the proposal falls below its accuracy under the current best.

That's the previous post's third guardrail, applied per round: fixing `currency` doesn't count if `total` gets worse. The rejected proposal is saved, and the next round works from whatever is failing then.

Flat changes are accepted too, because a fix often takes two edits to land. Only strict improvement resets the stall counter, so a run can't drift sideways forever.

The comparison has a 0.05-point tolerance. Without it, ties were rejected because the stored best accuracy was a 32-bit float (83.3333 became 83.333336) compared against a fresh 64-bit number.

## What it does not do

**There is no held-out split.** Every labeled document both steers the edit and scores it. Corpus scoring plus the regression rule stops the loop from fixing one document at the others' expense; it does not show the schema generalizes beyond the corpus. A small corpus can be fit exactly. The more labeled documents you have, the more a passing score means.

**It can't change the labels.** This is the guardrail that matters most here. A tuning run writes only its run record, its round history, and per-document scoring rows; the model's only output is schema YAML. Ground truth comes from people: the ground-truth builder and corpus labeling queue show proposed values for a human to confirm or correct (including by drawing a box on the document), and agent-drafted labels from the review queue stay out of the scored copy until a human approves them. The loop is trying to raise the score and has no way to touch the answer key.

**It doesn't ship anything.** A run ends with a best schema stored on the run. It creates no candidate version and changes nothing live. Then three deliberate steps:

1. **Apply improved schema** loads it into the editor.
2. **Validate candidate across corpus** runs a normal validation, which creates a release candidate as described in the previous post.
3. **Promote to live** is disabled in the panel if that validation showed regressions. The server enforces the same rule: it refuses with a `409` if the candidate's latest validation run recorded any.

So the agent can only change the schema, and a human makes every release.

## Showing the real reasoning

Each proposal includes the model's reasoning. The tuner prompt asks for a short `<thinking>` block before the YAML: which field it's working on, what the document shows, whether the failure is routing or wording, and what it plans to change. That text is the model's own output, not a template filled in afterwards, saved with the round alongside the proposed YAML.

A number alone doesn't let you check anything. If accuracy goes from 83% to 100%, you want to know how. "This field's guidance should say grand total, not subtotal" you can sanity-check in a second. A fix that writes one document's value into the guidance is one you need to catch. With the reasoning next to the diff, you can review it. With a spinner and a final score, you can't.

Be precise about where it streams. The OpenAI and Anthropic providers gained a streaming generate path, and the in-request API endpoint (`POST /api/schemas/{slug}/tune/corpus-loop`) relays the reasoning token by token as a `thinking` server-sent event. The dashboard panel runs the durable version below: it polls, and each round's reasoning appears once that round is scored. Between rounds it shows live progress like "Scoring the baseline across the corpus — 12/40 documents".

## Why runs are durable

The first dashboard version ran the whole loop inside one request. On a real corpus it hit the API's 300-second function limit and died partway through. Closing the tab also killed it.

Now a run is a row in the database, advanced by background jobs:

- Starting a run creates a `tune_runs` record and queues the baseline scoring pass.
- Each scoring pass **fans out one job per document**. Each job extracts one document and writes one row. A retried job overwrites its own row, so nothing is counted twice.
- When the last document arrives, one job aggregates the pass. It's picked by an atomic compare-and-swap on the run's phase, so two documents finishing at the same moment can't both finalize it.
- Proposing an edit is its own job, which then starts the next fanned-out scoring pass.

No job extracts more than one document, so corpus size never meets the time limit, and documents score in parallel. A baseline pass that used to sit silent for minutes in one job now reports progress per document.

Every round is persisted: reasoning, proposed YAML and its hash, focus document, targeted fields, regressions, and whether it was kept. The panel reattaches to an in-flight run when it opens, so you can close the tab and come back.

The saved history also feeds the next round. Before each proposal, the run reads the explanations of its rejected rounds (the most recent six) and puts them in the prompt under "already tried and rejected — do not repeat these".

## The loop was only as smart as its plumbing

Two first-day bugs made the tuner look dumber than it was.

First, the tuner diagnosed failures correctly and never returned a proposal: `proposedYaml` was always null. The model wrapped its schema in a ` ```yaml ` fence; the parser only accepted a `<yaml>` tag. Now it accepts either.

Second, proposals compiled and changed nothing. The tuner wrote hints as `extraction_guidance`; the build/validate/tune extraction path read `extraction_hint`. The hint was silently ignored. With the keys treated as synonyms everywhere, a real document went from 83% to 100% on one proposal. The same release fixed a try/catch compile check around a compiler that *returns* errors rather than throwing.

Neither bug was the model. Both surfaced by running the loop on real documents and asking why the number didn't move. When an agent loop looks stuck, check the plumbing first.

---

Auto-tune doesn't add new guardrails. The guardrails were already there: ground truth only a human can approve, validation that can't deploy, and promotion that won't release a regression. Auto-tune runs a loop inside them, adds a rule so a single round can't trade one field for another, and shows you the model's reasoning so you can check its work.
