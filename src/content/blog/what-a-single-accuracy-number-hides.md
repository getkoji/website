---
title: "What a Single Accuracy Number Hides"
description: "A headline accuracy number mixes two failures you can't see: the pipeline being wrong and the answer key being wrong. Here's how we pulled them apart on a 1,114-document benchmark."
date: 2026-09-03
author: "Frank Thomas"
tags: ["extraction", "methodology", "benchmarks"]
---

Every extraction system reports one number. "94% accurate." Ours says 88% on a simplified pipeline. But a single accuracy number is a ratio of two things you can't see: how often the pipeline is wrong, and how often the *answer key* is wrong. Until you separate them, you don't actually know what the number means.

Here's how we pulled them apart on a 1,114-document benchmark — and what fell out when we did.

---

## The problem with "accuracy"

Field-level accuracy is `correct fields / total fields`. To compute it you need ground truth: the expected value for every field of every document. And there's the rub — your ground truth was made by *something*. Usually a model seeded the values and a human reviewed them. So when the pipeline disagrees with ground truth, you're looking at one of two failures and you can't tell which:

1. **The pipeline is wrong.** It missed a value, invented one, or got it slightly off.
2. **The ground truth is wrong.** The answer key has the error, and the pipeline was actually right.

A headline accuracy number bundles these together. If you "improve" the pipeline until it matches ground truth, you might just be training it to reproduce the answer key's mistakes. And if your ground truth was seeded by the same model you're now evaluating, the number is flattering by construction — the model agrees with itself.

We wanted a number we could trust. That meant measuring the answer key, not just the pipeline.

## Step 1: measure how much the answer key moved

Our ground truth was seeded by running GPT-4o-mini, then corrected by a domain-knowledgeable reviewer per category. If the reviewers had just rubber-stamped the model's output, ground truth would be worthless — it would be a copy of the thing we're evaluating.

So we re-ran the seeding model and measured where its output diverges from the reviewed ground truth. Across 7,121 fields, 829 (11.6%) differ. The shape of those changes is the tell:

| Change | Count | Share | What it means |
|---|---|---|---|
| **Enrichment** — model returned null, reviewer filled in a value | 349 | 42% | Reviewers caught fields the seed missed |
| **Hallucination rejection** — model invented a value, reviewer set it to null | 152 | 18% | Reviewers caught fields the seed invented |
| **Value disagreement** — both had a value, reviewer changed it | 245 | 30% | Reviewers corrected wrong values |

Reviewers changed one field in nine, and the changes go in both directions — adding missed values *and* deleting invented ones. That's the signature of active correction, not rubber-stamping. If reviewers had only ever accepted the seed, the table would be empty. It isn't.

But "the reviewers worked hard" isn't the same as "the ground truth is right." For that we needed an independent check.

## Step 2: have a second pipeline re-extract blind

A second engineer built a completely independent extraction pipeline — different code, different prompts, no access to our implementation or results — and ran it against the same corpus. The question: how often does an independent system, that never saw our answer key, agree with it?

We call that **concordance**. It's the document-AI analog of inter-annotator agreement: if two independent processes converge on the same value, the value is probably right. If they don't, something's wrong — and now you get to ask *what*.

A blind 10% pilot (110 documents) came back at **89.1% concordance**. Encouraging enough to run the locked protocol on all 1,114 documents (7,197 fields). The full-corpus result: **86.6% field agreement** with ground truth, using GPT-4o-mini.

## Step 3: decompose the disagreement

86.6% concordance means 13.4% of fields disagreed. This is the number that actually teaches you something — *if* you decompose it instead of staring at it. The 13.4% breaks into three kinds of disagreement:

| Disagreement | Share of all fields | What it is |
|---|---|---|
| **Value mismatch** | 7.5% | Both systems extracted a value; they differ |
| **Hallucination** (by the independent system) | 3.4% | Ground truth is null; the independent system invented a value |
| **Missing** (by the independent system) | 2.4% | Ground truth has a value; the independent system returned null |

This decomposition is the whole point. The 13.4% is not "13.4% ground-truth error." It's dominated by *value mismatches* (7.5%) — two systems reading a hard document and landing on different values — plus the independent system's own hallucinations and misses (3.4% + 2.4%). These are extraction failures of the *second* pipeline, not evidence that the answer key is wrong. A genuinely broken answer key would produce systematic, lopsided disagreement; what we see is the ordinary noise of two independent systems doing a hard task.

The decomposition also tells you where to spend engineering effort. Value mismatches dominate, so the lever is normalization and disambiguation — not abstention tuning, which is what you'd reach for if missing fields dominated. The number doesn't just grade you; it points.

## Step 4: confirm the answer key isn't anchored to one model

There's one more failure mode: maybe ground truth is calibrated to GPT-4o-mini specifically, and any GPT-4o-mini pipeline will agree with it for the wrong reasons. So we ran a structurally different model, GPT-5.4-nano, through the same protocol. It scored **82.2%** — lower. If ground truth were just "whatever GPT-4o-mini says," a different model wouldn't track it at all. The benchmark discriminates between systems, which is exactly what a benchmark anchored to *reality* (not to one model) should do.

## What you actually learn

Run this and you stop having one number and start having four:

- **How much the answer key was corrected** (and in which direction) — is your ground truth a copy of the model or a correction of it?
- **How often an independent system agrees** — concordance, the trust floor under your accuracy number.
- **What the disagreement is made of** — value vs. hallucination vs. missing, which tells you what to fix.
- **Whether a different model still tracks it** — is the benchmark measuring reality or measuring one model's habits?

A headline accuracy number collapses all of that into a single digit that can't distinguish a great pipeline with a broken answer key from a mediocre pipeline with a perfect one. The decomposition is more work. It's also the difference between a number you quote and a number you trust.

---

*This post describes the ground-truth validation methodology behind the Koji extraction benchmark — 1,114 documents, 12 categories, ~7,200 fields. The four-way scoring it relies on (correct / missing / hallucinated / correctly-absent) is covered in [Null Semantics: There's More Than One Right Answer](/blog/null-semantics-right-answer). The corpus and evaluation tooling are open at [github.com/getkoji/corpus](https://github.com/getkoji/corpus).*
