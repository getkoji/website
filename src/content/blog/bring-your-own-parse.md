---
title: "Bring Your Own Parse"
description: "Koji already lets you bring your own model. Now you can bring your own parse engine too — because the OCR layer sets the accuracy ceiling, and because honest-but-rough beats confidently-wrong on a regulated document."
date: 2026-09-10
author: "Frank Thomas"
tags: ["extraction", "parsing", "ocr", "architecture"]
---

Koji has always been bring-your-own-model. You configure your own LLM endpoint, your credentials are encrypted, and you pay the model vendor directly — we never mark up inference. Today we're extending that to the layer underneath the model: **bring your own parse engine.**

If you've used Koji, you know parse is the first stage of the pipeline — the step that turns a PDF into text the model can read. It's easy to think of it as plumbing. It isn't. Parse quality is the single biggest lever on extraction accuracy that nobody talks about, and the right parse engine depends on your documents in ways no single default can satisfy. Here's why we made it pluggable, and what we learned that made it urgent.

---

## Parse sets the ceiling

Every clever thing that happens downstream — routing the right chunks to the model, validating field types, scoring confidence — operates on the text that parse hands up. None of it can recover information that parse destroyed.

A concrete example we hit in production: a "declarations page" — the table-dense summary at the front of an insurance policy — went through a parser that flattened its multi-column tables into a single stream of text in the wrong reading order. The coverage limits ended up visually adjacent to the wrong coverage names. The model then dutifully extracted the wrong limit for the wrong coverage. Nothing in the extraction layer was broken. The chunk router did its job. The model followed instructions. The answer was wrong because *the text was already wrong before the model ever saw it.*

Chunk selection optimizes given good text. It cannot un-garble bad text. Parse quality is the accuracy ceiling, and on the hard tail — faxed certificates, dot-matrix loss runs, handwritten annotations, multilingual carrier forms — the open-source default (EasyOCR, via docling) hits that ceiling well below where customers in regulated workflows need it. When an expiration date drops because the scan was rough, somebody notices.

Better OCR exists. Vision-LLM OCR and the major clouds' document services are meaningfully stronger on exactly that hard tail. The catch is that the good options cost money per page — which brings us to why this is BYO and not "Koji eats it."

---

## OCR is an inference cost, and inference costs belong on your bill

Koji's pricing philosophy is explicit: margins are high because inference runs on *your* books, not ours. You bring your own model key; you pay your model vendor directly; we charge for the platform. That's the deal, and it's the reason we can keep the platform price predictable.

OCR is just another inference cost. If we bundled a premium OCR engine into a flat platform tier, the first customer who bulk-imports a few thousand multi-hundred-page documents would quietly turn that account deeply unprofitable — and to defend the margin we'd have to cap page counts and throttle exactly the power users we most want. We've seen the numbers on our own traffic; parse, not model inference, is the real variable cost of running this platform. Putting it on a flat tier breaks the model the first time someone does a big import.

So premium parse follows the same rule as premium models: **you bring the key, you pay the vendor, we charge for the platform.** The free, zero-config default stays free — most digital PDFs parse in-process for effectively nothing, and you never have to configure anything to get started. BYO parse is opt-in, for when your documents need a stronger engine than the default. The shape is identical to the model catalog you already use:

- `Settings → Parse Endpoints`: add a provider — Mistral OCR, Azure Document Intelligence, Google Document AI, or AWS Textract — and give it a credential (encrypted at rest; Google Document AI can also run keyless via Workload Identity Federation).
- Share an endpoint across every project in your workspace, or add one to a single project to override the shared one there. You can also pin a specific endpoint to an individual pipeline.
- Documents that need real parsing — scans and images — route to your configured engine; the bill goes to the vendor, not through us.
- Digital PDFs with a text layer keep parsing in-process with the free default, so you don't pay an OCR vendor for pages that don't need OCR.

---

## We tested the OCR vendors. The result is the whole argument for BYO.

Here's the part that turned "nice to have" into "ship this." Before recommending any OCR engine, we ran real customer documents — the genuinely hard ones, faxed and scanned and partly blank — through several vendors and scored them honestly.

One of the documents had blank pages in the middle: scanned filler, no content. A frontier vision-LLM OCR engine *fabricated entire tables* on those blank pages — confident, well-formatted, plausible-looking rows of data that did not exist anywhere in the source. (They weren't even in the right language.) A deterministic cloud OCR service, given the same blank pages, returned empty. Because that's the correct answer.

On the genuinely hard pages — the faxed, degraded scans where good OCR earns its price — the two were a near dead heat on raw text recovery. So the vision-LLM engine bought you no accuracy edge to offset its willingness to invent data on the pages where it had nothing to read.

For a regulated document — an insurance policy, a claim, a filing — **honest-but-rough beats confidently-wrong, every time.** A field that comes back empty routes to human review. A fabricated field that looks perfect sails straight through and becomes wrong data in a system of record. The failure modes are not symmetric, and the expensive one is the one that looks fine.

That's not an argument for one vendor over another. It's an argument for *choosing per workload, with your eyes open* — which is exactly what BYO parse is for. We're not going to silently default everyone to whichever engine demos best. You pick the engine that fits your risk tolerance and your documents, and where it matters we'll tell you what we found.

---

## Vendor-neutrality is the moat, not a liability

The obvious worry about sitting on top of someone else's OCR is channel conflict: what stops the parse vendor — especially a frontier lab that already emits structured JSON — from climbing the stack and taking the whole deal?

Being portable across vendors is the defense, not the exposure. A model emitting JSON from a single OCR call is not a document-processing platform. It won't build you a schema authoring loop, a classification router, a validation layer, a human review queue, a versioned corpus, provenance, audit trails, or multi-tenancy. Koji is that platform — and by sitting on top of *any* parse engine and letting you switch without re-tooling, we make parse engines interchangeable commodities underneath. That's the opposite of being a vendor's channel. It's the layer that protects *you* from lock-in.

So the guidance we give is by segment, and it's honestly about your existing relationships, not ours:

- **Small and self-serve:** a markdown-native OCR API you can put on a credit card in minutes. Cheap, no procurement.
- **Enterprise:** your existing cloud's document OCR — Azure Document Intelligence, AWS Textract, or Google Document AI. You've already procured it under a contract you already have. Zero net-new vendors, no second deal.
- **Don't-make-me-set-anything-up:** an opt-in managed-parse path where we procure it and hand you one bill, clearly priced and never the default. This one is planned, not shipped yet.

Bring your own parse, bring your own model. Koji is the portable platform across both — and the one place that will tell you, with receipts, which engine actually deserves your documents.
