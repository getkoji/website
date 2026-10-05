---
title: "The Economics of Document Extraction"
description: "Everyone budgets for model tokens. Almost nobody budgets for parse. But on real traffic, turning the PDF into text — not running the model — is the variable cost that decides whether your unit economics work."
date: 2026-07-06
author: "Frank Thomas"
tags: ["extraction", "parsing", "economics", "infrastructure"]
---

When people estimate what document extraction costs to run, they think about the model. Tokens in, tokens out, dollars per million. It's the line item everyone watches because it's the one the model vendors put on an invoice.

It's also, on real traffic, often not the line item that matters most. The cost that quietly decides whether your unit economics work is **parse** — the step that turns a PDF into text before the model ever sees it. Here's what we learned looking at costs honestly on our own platform, and why it changes how you should price anything that processes documents.

---

## Two costs, two very different shapes

A document extraction pipeline has two variable costs:

1. **Inference** — running the LLM to pull structured fields out of the text.
2. **Parse** — turning the source document into that text in the first place.

Inference is the one everyone models. But inference can be made someone else's problem: if customers bring their own model key, inference cost lives on *their* bill, and the platform never marks it up. That's the bring-your-own-model deal, and it's why a well-designed extraction platform can have genuinely high margins — the biggest-looking cost isn't on its books at all.

Parse is different, and parse is bimodal. A clean digital PDF — one that already has a text layer — parses essentially for free, in-process, no external service. But a *scanned* page, a faxed certificate, a dot-matrix loss run, anything that needs real OCR, costs real money per page. The distribution isn't smooth. Your document mix is some fraction of nearly-free digital PDFs and some fraction of pay-per-page scans, and your blended cost depends entirely on that ratio — which varies wildly by customer.

The trap is that parse *feels* like infrastructure — plumbing, a fixed cost of doing business — when it's actually your dominant variable cost. We found this the direct way: looking at our own per-page parse spend and realizing that our back-of-envelope "cost per document" estimate had left it out entirely. That estimate, like everyone's, had silently budgeted for tokens and ignored OCR.

---

## Why a flat per-document price is a trap

Here's the failure mode this sets up. You price your platform at a flat rate per document — clean, simple, easy to sell. It works great on the average customer, whose documents are mostly digital and a few pages each.

Then one customer does a bulk import: ten thousand scanned, multi-hundred-page documents from a historical archive. Every page needs OCR. Every page costs you money. That single customer, on the same flat per-document price as everyone else, can go from your best logo to a line item that's underwater — not because they're abusing anything, but because *page-heavy, scan-heavy* is a cost profile the flat price never accounted for.

And the instinct to defend against it makes the product worse. You add page caps. You throttle large documents. You push your most engaged power users toward an "enterprise conversation" purely because their documents are big. You end up rationing the exact usage you should want, because the pricing model can't absorb the cost shape.

The structural fix is the same one that works for inference: **don't put the variable cost on your books.** If premium parse — the good OCR that handles the hard tail — is bring-your-own-key the same way the model is, then the customer who bulk-imports ten thousand scans pays their OCR vendor directly for those ten thousand scans. The cost scales with the customer who incurs it, the platform price stays predictable, and nobody has to invent a page cap to protect a margin.

---

## What this means if you're building on documents

A few things fall out of taking parse seriously as a cost center:

**Measure parse separately from inference.** If your cost model has one "per document" number, you've almost certainly blended a near-free operation (digital parse) with an expensive one (OCR) and lost the signal. Split them. The first time we looked at parse on its own, the picture changed.

**Know your document mix.** "Cost per document" is meaningless without the digital-vs-scanned ratio. A customer who sends you clean carrier PDFs and a customer who sends you faxed onboarding paperwork have order-of-magnitude different cost profiles on identical-looking volume.

**Don't let cost masquerade as a technical limit.** When you see a page cap on a document product, it's worth asking whether it's a real processing constraint or a cost-control measure wearing a technical costume. Usually it's the latter — and if the per-page cost moves to the customer, the cap can rise or disappear, gated on actual quality limits instead of on your margin.

**Premium quality and cost ownership are the same decision.** The better OCR that recovers the hard tail is exactly the OCR that costs per page. Bundling it into a flat tier is what breaks the economics. Making it opt-in and customer-funded is what lets you offer it to everyone who needs it without rationing.

---

The headline number in document AI is always accuracy, and the cost everyone quotes is always tokens. But the operation that decides whether the business underneath works is the unglamorous one at the very front of the pipeline — the one that turns a smudged fax into text. Budget for parse. It's where the money is.
