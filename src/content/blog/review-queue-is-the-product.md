---
title: "The Review Queue Is the Product"
description: "Most document AI vendors treat human review as the embarrassing fallback for when automation fails. We treat it as the core feature — the part that makes the rest trustworthy."
date: 2026-06-29
author: "Frank Thomas"
tags: ["extraction", "hitl", "product", "strategy"]
---

The pitch you hear from most document AI vendors is *full automation*. Upload your documents, the AI extracts everything, no humans required. Human review, in that story, is the embarrassing part — the asterisk, the thing that happens when the magic doesn't work, the cost you're promised will shrink to zero as the models get better.

We build the opposite way. The human review queue isn't the fallback in Koji. It's the product. The extraction exists to *feed* the review queue intelligently — to decide what a human needs to look at and what they don't — and getting that decision right is most of the value. Here's why we think the "no humans" framing is selling the wrong thing.

---

## "99% accurate" is a claim about the 1% you can't see

Every extraction vendor claims a high accuracy number. Set aside whether the number is real for a second and ask the harder question: *which documents are in the 1% it gets wrong, and how do you find them?*

In a fully-automated pipeline, you can't. The wrong extractions look exactly like the right ones — structured JSON, confidently populated, flowing straight into your system of record. A wrong expiration date and a right expiration date are the same shape. The error doesn't announce itself. You discover it later, downstream, when a policy that was supposed to be active turns out to have lapsed, or a claim routes to the wrong adjuster, and you trace it back to a field that was wrong from the start and nobody ever looked at.

"99% accurate" means nothing operationally if you can't tell which documents are in the 99 and which are in the 1. Automation without review doesn't eliminate the errors — it just makes them invisible until they're expensive.

---

## The job is triage, not extraction

So the real job of an extraction system isn't "extract every field correctly." No system does that on the messy tail of real documents — the faxes, the handwriting, the carrier form nobody's seen before. The real job is **knowing which extractions to trust and which to flag.**

That reframes everything. A pipeline that confidently extracts a wrong value and ships it is *worse* than one that extracts the same wrong value but flags it as uncertain and routes it to a human. Same error, opposite outcome: one becomes silent bad data, the other becomes a thirty-second human correction. The flag is the feature.

Which means the most important number isn't accuracy — it's *calibration*. Does the system know when it doesn't know? A well-calibrated pipeline sends the genuinely hard documents to review and lets the easy ones flow through untouched, so the human spends their attention only where it changes an outcome. A poorly-calibrated one either floods the queue with false alarms (and the reviewer learns to rubber-stamp) or stays confidently silent on real errors (and the errors ship). The review queue is where calibration becomes visible, and calibration is the whole game.

---

## The queue is also your best dataset

There's a second reason the review queue is central, and it compounds over time. Every document that lands in review is, by definition, a document the current configuration couldn't handle confidently. That's not waste — that's a perfectly labeled list of exactly where your extraction is weak.

So the queue isn't just an operational surface, it's a *training signal*. The documents that get flagged this week tell you which fields to strengthen. The human corrections become ground truth. You improve the configuration so that whole class of document stops getting flagged — and next week's queue is the harder tail you hadn't reached yet. The review queue is the mechanism by which the system gets better at its job, continuously, from real traffic. A fully-automated black box throws that signal away because it never admits which documents were hard.

(We've built that loop explicitly — flagged documents flow into a versioned corpus, and the schema improves against it. But the point stands even if you build it by hand: the queue is where you learn what to fix.)

---

## Why the "no humans" pitch undersells the work

I understand why vendors lead with full automation. "Fire your data-entry team" is a cleaner sales line than "make your data-entry team dramatically more leveraged." But it's selling against the grain of what the buyer actually needs, especially in regulated work — insurance, claims, healthcare, finance — where a wrong field isn't an inconvenience, it's a liability.

In those domains the human reviewer isn't a cost to be eliminated. They're the accountable party — the person who can be trusted to have *looked* at the things that mattered. The value of the product isn't removing them from the loop. It's making their loop tight: surfacing the handful of documents and fields that genuinely need a human, with the context to resolve each one in seconds, and getting out of the way on everything else.

That's a better product than "no humans." It's also a more honest one. The documents will keep getting weirder than your model expects, because the world keeps producing weird documents. A system that's built around *handling* that — flagging it, routing it, learning from it — ages well. A system that's built around pretending it won't happen ages into a pile of silent errors.

The review queue isn't where our product admits defeat. It's where it does its most important work.
