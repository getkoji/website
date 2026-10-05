---
title: "Two OCR Upgrades We Killed"
description: "Two OCR upgrades that worked in the demo and died in the spreadsheet. A short field report on rejecting good ideas for boring reasons — latency and cost — before they become tech debt."
date: 2026-07-09
author: "Frank Thomas"
tags: ["extraction", "ocr", "engineering"]
---

Most engineering writing is about what shipped. But a lot of the actual work is deciding what *not* to ship — and the decisions to kill something are often more useful to read than the launch posts, because they show you where the real constraints are.

In late June we spiked two ways to get materially better OCR text out of our document pipeline. Both worked. Both produced output noticeably better than our baseline. We rejected both, for two of the most boring reasons in engineering: one was too slow, and the other was too expensive. Here's the field report.

---

## The problem both were trying to solve

Our default OCR — docling's OCR pass for the text the model reads, and Tesseract (via OCRmyPDF) for the searchable text layer on scans — produces text that's *consistently rough*. Typos, mis-segmented words, the occasional whole-word misread on a noisy scan. It shows up in two places a user can see:

1. **Extraction quality** — the model reads garbled text and extracts garbled fields.
2. **Search** — a user opens a scanned document, hits ⌘F, searches for a company name, and finds nothing, because Tesseract misread a single letter in it. They blame us, not Tesseract.

The garbled-string case is the one that stings, because some of those errors have no string-distance fix. In one real scan, Tesseract turned "Law Offices of" into "uw pauses of." No fuzzy match recovers that. You need something that understands the text, not just its character distance from the original.

So: two candidate upgrades.

---

## Candidate 1: a self-hosted vision-LLM OCR model

The first idea was to replace our OCR wholesale with a modern open-source vision-language OCR model — one of the new ones that does layout detection and text recognition in a single pass, emits bounding boxes inline, and tops the document-OCR benchmarks. On paper it was ideal: better text *and* position data *and* potentially a searchable-PDF rebuild, all from one inference call, all self-hostable so nothing leaves our infra.

We stood it up on a GPU and ran a real 38-page scanned document through it.

**The quality was genuinely excellent.** On clean pages it crushed our baseline — correct proper nouns, preserved punctuation, real paragraph structure. The inline bounding-box output was real and usable.

**The latency was a dealbreaker.** About 150 seconds *per page*. The architecture explains it: an autoregressive model generates its output one token at a time, throughput bounded by GPU memory bandwidth, and a dense page is a couple thousand tokens. Our baseline doesn't generate its output token by token, so it isn't bound the same way. The numbers that killed it:

| Document | Vision-LLM OCR | Our baseline |
|----------|----------------|--------------|
| 38-page scan | ~75–90 min | < 1 min |
| 150-page policy | ~4–5 hours | < 1 min |
| 226-page policy | ~5–7 hours | ~minutes |

The test document hit the function timeout after six pages. Even on a top-tier GPU it would stay 5–10× slower than the baseline for long documents — and long documents are exactly what we routinely process. We process multi-hundred-page policies as a matter of course; a parser that takes an afternoon per document isn't a parser, it's a batch job you apologize for.

**There was also a quieter problem:** on page one of the test doc, the model got stuck in a repetition loop and *fabricated text* — "...part of the Federal Trade Commission, which is a part of the Federal Trade Commission..." — content that wasn't in the source. For an extraction pipeline feeding regulated workflows, a confident fabrication is worse than an honest typo. The typo routes to review; the fabrication sails through and becomes wrong data.

**Verdict: rejected on latency.** We kept the spike reproducible and wrote down exactly what would make us revisit — a major throughput improvement, a speed-optimized fork (the model is open-source, so plausible), or a customer who specifically wants self-hostable quality-first OCR and will accept the latency. Until then, the throughput gap is just too large.

---

## Candidate 2: let the model fix the OCR

The second idea was cleverer and got much further. Instead of replacing Tesseract, *correct* it. Keep Tesseract as the fast baseline that defines text positions, then run each page image plus its rough Tesseract text through an LLM with one instruction: fix the OCR errors, preserve the line structure exactly, one line out per line in. The corrected text feeds extraction; a line-level alignment step maps it back onto Tesseract's bounding boxes to rebuild a clean searchable layer. Failure degrades gracefully — any line the model drops falls back to the original Tesseract text, so it can never produce *worse* output than baseline.

**It worked, and the quality was excellent.** A line-numbered-prefix prompt produced strict 1:1 line alignment safe to feed into a bbox-preserving rewrite. On the hard cases it caught exactly the semantic errors a fuzzy-distance approach can't:

| Tesseract | Corrected |
|-----------|-----------|
| `Tvoe: CRP` | `Type: CRP` |
| `DRAWN'BY` | `DRAWN BY` |
| `RK 1957 1984-2021` | `BK 1957 PG 1984-2021` |
| `uw pauses of [attorney name], P.A.` | `Law Offices of [attorney name], P.A.` |

That last one is the whole reason we tried this. There's no string-distance solution to "uw pauses of" → "Law Offices of." The model gets it because it understands what the line is supposed to say.

We also learned a nice secondary result: for this particular task, a mid-tier model beat the frontier one outright — same correction quality at roughly a third of the cost and meaningfully faster, because the task doesn't need deep reasoning, just good vision and a steady hand. Reaching for the biggest model would have been the expensive wrong default.

**So why kill it?** Cost — at the wrong ratio. Every page is an LLM vision call. At baseline, with no optimization, a typical multi-page document lands around \$0.60, and a big policy several dollars. On a low per-document revenue tier, even on the customer's own bill, that's roughly a 6× tax over the platform fee. Not catastrophic, but loud enough to *feel* expensive — and "feels expensive" is a real product cost, not just a spreadsheet one.

**Verdict: parked on cost, with a clear path back.** The difference from candidate 1 is that the levers here are known and cheap, and we ranked them: prompt caching (free, 30–40% off multi-page docs), a smaller model (another spike to validate quality holds), and confidence-gated correction (only re-OCR the pages Tesseract is unsure about — Tesseract already emits per-word confidence). Stacked, those should pull a large document back down into "incremental cost of doing business" territory. We didn't ship it now because the OCR baseline had only just shipped and we don't yet have the production feedback to know how badly we need it. When a second customer complains, or selectable-text accuracy becomes load-bearing for a workflow, the plan is written down and the prompt design is recorded — we lift it instead of re-deriving it.

---

## Why write the rejections down

Both of these were good ideas. Both demoed well. The reason to kill them — and the reason to *document* killing them — is that a good idea with bad unit economics doesn't announce itself as bad. It announces itself as a working demo, and working demos are how tech debt gets adopted.

So we write down the kill: what we tried, what it actually cost in latency or dollars, and the specific trigger that would make it worth revisiting. That turns a dead end into a parked option. The next time someone says "what if the model just fixed the OCR?" the answer isn't "let me think about it" — it's "we did, here's the spreadsheet, here are the three levers, and here's the customer signal that flips the decision."

The boring reasons — too slow, too expensive — are usually the real ones. Writing them down is how you stop relitigating them.
