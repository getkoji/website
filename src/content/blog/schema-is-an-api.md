---
title: "Your Extraction Schema Is an API. Version It Like One."
description: "If a downstream system reads the JSON your extraction pipeline produces, the schema is a public contract. Here's why we made schema versions real semver — auto-derived from the output shape — and what that buys you."
date: 2026-07-02
author: "Frank Thomas"
tags: ["extraction", "schemas", "architecture", "versioning"]
---

An extraction schema feels like configuration. It's a YAML file, you tweak a field description, you re-run. Configuration is the kind of thing you change casually.

But the moment a downstream system reads the JSON your pipeline produces — a claims platform, a COI tracker, a database, anything — that schema stops being configuration and becomes a **contract**. If you rename `effective_date` to `policy_start`, or change `premium` from a number to a string, or make a previously-required field optional, something on the other end breaks. Quietly, usually, and at the worst possible time.

We treat that contract the way you'd treat any public API: with real versions that mean something. Here's how it works and why it matters.

---

## The footgun we started with

For a long time, validating a schema change had a nasty side effect: it shipped. Running `koji validate` against a schema didn't just *test* the new version — it persisted it and immediately made it live for every production pipeline using that schema, before validation even finished, pass or fail.

So an agent (or a person) backtesting twenty edits in a row would flip the live production schema twenty times. Every experiment was a deploy. That's the kind of coupling that's fine right up until it isn't, and then it's a 2 a.m. incident.

The fix was to separate two things that had been fused: *snapshotting a version* and *making it live*. Now `validate` snapshots a **release candidate** — a real, persisted, fully traceable version tagged `v0.0.4-rc.7` — that never activates. Production keeps running the current released version no matter how many candidates you churn through. Going live is a separate, permission-gated, manual step:

```bash
koji validate ./schema.yaml            # snapshots a candidate, backtests it, touches nothing live
koji schema promote <slug>             # graduates the candidate and makes it live (gated)
```

(There's also `koji schema release`, for early-stage schemas with nothing in the corpus to backtest yet. It skips the candidate loop, but it's gated by the same deploy permission.)

Safe to iterate, gated to ship. But the more interesting half is what the version *number* means.

---

## Semver that's actually derived from the contract

Most versioning is manual and therefore lies. Someone bumps a minor version when they should've bumped a major, the number drifts from reality, and you stop trusting it.

A schema has an unusually crisp definition of "breaking," though: the **output shape**. And because the engine already parses every schema into a structured representation, we can diff a candidate against the current release and *derive the version bump automatically* — no judgment call, no ceremony (a `--bump` flag lets a human override it when the heuristic gets it wrong):

| Bump | Meaning | What triggers it |
|------|---------|------------------|
| **major** | output shape changed — consumers can break | a field removed, renamed, or retyped; **required → optional** (the field may now be absent); a nested array/object child removed or retyped |
| **minor** | additive or stricter — safe for consumers | a new field; a new nested child; **optional → required** (stricter); an enum domain change |
| **patch** | same shape, better extraction | hints, descriptions, prompts, normalization — anything that doesn't change the output's structure |

The direction matters and it's easy to get backwards. `required → optional` is the *breaking* one, because a consumer that was relying on the field always being present can now get nothing. The reverse — `optional → required` — only makes the output stricter, which never breaks a reader. The diff encodes that asymmetry so you don't have to remember it.

The payoff: the version string is now load-bearing information. A consumer pinned to `v1.x` can trust the output shape won't move under them. A jump to `v2.0.0` is a flag that says *check your integration before you take this*. For a customer whose claims system is wired to your extraction output, that's the difference between a safe upgrade and a silent data corruption.

---

## The number that warns you before you ship

Here's my favorite consequence. Because the bump is derived from the shape diff, the candidate's *name* tells you the nature of the change before you promote it:

```
v2.0.0-rc.3 @ 96%
```

That candidate scores 96% accuracy — looks great, ship it, right? Except the `2.0.0` says this is a **breaking** change to the output contract. High accuracy and breaking-the-downstream are completely orthogonal, and a naive "promote when the number is good" reflex would walk you straight into the second one. The version name surfaces the risk that the accuracy number hides. An agent reading that string knows to flag it for a human; a human reading it knows to check what shape changed before flipping it live.

Promotion is always manual for exactly this reason. There's no auto-promote-on-threshold. There's an optional `--require-no-regressions` *guard* that will refuse to promote a candidate whose latest validation run recorded regressions — but it only ever *blocks* a promote, it never triggers one. The decision to change a production contract stays a human decision.

The same rule covers every other path to going live: a release ships exactly what you asked for, or it fails loudly. Publishing YAML that's byte-identical to an existing version reuses that version rather than creating a duplicate — and we found that this dedup could quietly repoint the live release at an *older* version while returning an ordinary success. Now, if publishing would move the live release to a different existing version, the API refuses with a `409` that names both versions and says whether it would be a rollback; going backward takes an explicit promote. Likewise, a release request whose body doesn't carry recognizable schema YAML is rejected, instead of falling back to whatever draft happens to be stored on the server.

---

## Staged rollout without an orchestration system

Once promoting changes the schema's active release, the next question is how each pipeline reacts. Forcing every pipeline to jump simultaneously is how you turn one bad schema change into a fleet-wide outage. So reacting is each pipeline's own choice:

- **`auto`** (the default) — the pipeline always runs the current released version. Promote, and it picks up the new release immediately.
- **`pinned`** — the pipeline stays on a specific version until you explicitly bump it.

(One caveat as of this writing: pipelines defined in pipeline YAML honor `auto`, but simple single-schema pipelines still run the version they were last deployed with, so they need an explicit bump after a promote. That's a bug, and we're fixing it.)

That gives you staged rollout with no extra machinery. Pin your one critical pipeline, let the rest auto-follow, promote the new release, watch the auto pipelines for a while, then bump the pinned one when you're confident. It's canary deployment for extraction schemas, and it falls out of a single column on the pipeline.

---

## Why bother

Document extraction sits at a boundary. On one side, a messy human artifact — a faxed policy, a scanned claim. On the other, a structured record that some other system depends on. The whole value of the pipeline is being a *reliable* bridge across that boundary.

You can't be a reliable bridge if the shape of your output can change without anyone noticing. Treating the schema as configuration invites exactly that — casual edits, silent breakage, a downstream team that learns about your "minor tweak" when their integration starts throwing nulls.

Treating it as an API — versioned, with the version derived from the contract itself, with a gated deploy and staged rollout — turns the schema into something downstream consumers can actually build on. The output stops being a thing that happens to come out of a model and becomes a thing with a promise attached. That promise is what makes it production software instead of a clever demo.
