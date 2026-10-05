---
title: "We Thought Our Ground Truth Was Wrong. It Wasn't."
description: "Contracts scored lowest in our extraction benchmark, and we wanted the answer key to be the problem. The test that settled it: a noisy target can't be climbed systematically."
date: 2026-09-17
author: "Frank Thomas"
tags: ["extraction", "methodology", "benchmarks"]
---

Our benchmark's blind concordance check — an independent pipeline re-extracting the corpus and comparing against our answer key — agreed with ground truth on up to 100% of fields in some categories. Contracts came back at 68.8%, the lowest of any category — and on a separate blind sample of 10 contracts (50 fields), 64%. Contracts were also our own pipeline's lowest-scoring category.

Our first instinct was the comforting one: the ground truth must be bad. Contracts are long, dense, and genuinely hard to annotate — surely the answer key was the problem, not the pipeline. We went looking for evidence to confirm that. We found the opposite.

---

## The comfortable hypothesis

When one category craters and the rest are fine, "the answer key is wrong" is the explanation you *want* to be true. It's not your pipeline's fault. It's a data-quality issue you can fix by re-annotating.

And contracts make the hypothesis plausible. A 50-page agreement has its governing-law clause on page 38, its effective date in a recital and again in a signature block (which one is "the" date?), party names that appear in a dozen forms. An annotator can reasonably disagree with another annotator. If ground truth is noisy, low concordance is expected and meaningless.

So we set out to test it. The trick is that **noise and difficulty look identical in the aggregate** — both produce a low number. You can only tell them apart by how the number *moves*.

## The test: can you systematically move a random target?

Here's the logic we leaned on. If the contracts ground truth were unreliable — effectively random noise — then no change to the pipeline could systematically improve agreement with it. You can't reliably climb toward a target that isn't there. A pipeline change that consistently raises the score against noisy ground truth is a contradiction; the only way to score higher against a fixed answer key, change after change, is if the answer key encodes something real.

So instead of asking "is the score low?" we asked "does the score *respond*?" We changed the pipeline in controlled ways and watched what contracts did.

**Routing.** Contracts are too long to feed whole, so the pipeline routes each field to the relevant sections. Turn routing off and extract from the full document instead, and contracts drop to **55.6%**. Turn it back on and they climb **+26 points** — the largest routing gain of any category in the corpus. Routing isn't random; it systematically selects the sections where the answers live. The fact that it reliably moves contracts by 26pp means the answers are *there*, in stable locations, waiting to be found. You cannot get a reliable 26-point lift against noise.

**Hints.** Strip the extraction hints and contracts fall to **69.6%**; add them back and they recover. Another systematic lever, another reliable response.

If ground truth were the problem, neither of these would behave. Routing would scatter, hints would be inert, and the score would wander. Instead, every lever we pulled moved contracts in a consistent, repeatable direction. That's the signature of a hard-but-real target, not a broken one.

## Difficulty has a shape, too

The difficulty story also fits the *structure* of the corpus. Sort every category by score and three tiers fall out cleanly:

- **Easy (>96%):** IRS forms, insurance policies, claims, invoices. Rigid structure, fixed fields, answers in predictable places. Routing barely matters (spread under 1pp) — there's nowhere for the answer to hide.
- **Medium (78–92%):** Certificates, SEC filings, legal filings, receipts, medical records, adversarial. Moderate layout variation.
- **Hard (<76%):** Contracts. Alone in the basement.

Contracts aren't an outlier *against* the pattern — they're the endpoint *of* it. The benchmark's difficulty axis is "how free-form is the layout, and how far is the answer from where you'd naively look." Contracts max out both. A 50-page negotiated agreement is the least structured, most variable document type in the corpus. Of course it's the hardest. The low score isn't noise contaminating a clean signal; it *is* the signal.

## Why this matters more than the number

The seductive thing about "our ground truth is wrong" is that it ends the investigation. You re-annotate, the number goes up a little, and you've learned nothing about your pipeline. The uncomfortable thing about "this is genuinely hard" is that it's actionable: contracts respond to routing (+26pp) and hints, so the lever is better long-document handling — section selection, dependency-ordered extraction, larger context windows — not another annotation pass.

A low score is data. Before you explain it away as a measurement problem, check whether it *responds* to changes in the thing you're measuring. If it moves systematically, your measurement is fine and your system has work to do. We wanted the answer key to be the problem. It was us. That's the more useful answer.

---

*This post is part of the methodology work behind the Koji extraction benchmark. The concordance metric it uses — independent blind re-extraction as a check on ground truth — is described in [What a Single Accuracy Number Hides](/blog/what-a-single-accuracy-number-hides). The corpus is open at [github.com/getkoji/corpus](https://github.com/getkoji/corpus).*
