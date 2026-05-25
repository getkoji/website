---
title: "Benchmarking Document Extraction: How We Measure Accuracy Across 1,100 Documents"
description: "Every document extraction vendor claims 95%+ accuracy. None of them publish how they measure it. We built an open, reproducible benchmark — here's the methodology."
date: 2026-05-10
author: "Frank Thomas"
tags: ["benchmarking", "methodology"]
---

Every document extraction vendor claims 95%+ accuracy. None of them publish how they measure it.

We built an open, reproducible benchmark for Koji — 1,100 documents, 13 categories, 7,121 fields with ground-truth expected outputs. Anyone can run it. Here's the methodology and what it revealed.

---

## The credibility problem

If you evaluate document AI products, you've seen the claims. "99% accuracy on invoices." "Enterprise-grade extraction." "Production-ready." The numbers are always high and the methodology is never published.

This makes the claims unfalsifiable. You can't reproduce them, you can't compare them, and you can't tell whether "95% accuracy" means 95% of documents had zero errors or 95% of individual fields matched expected values. These are very different numbers — a document with 10 fields where 1 field is wrong is 90% per-field but 0% per-document (it has an error). Neither framing is wrong, but publishing one without specifying which is misleading.

The NLP community solved this decades ago. Models are evaluated against standard benchmarks: SQuAD for question answering, GLUE for language understanding, ImageNet for computer vision. Every paper reports results on the same datasets using the same metrics. You can compare directly.

Document extraction has no equivalent. There's no SQuAD for invoices, no GLUE for insurance policies. Every vendor builds their own test set, measures against their own expected outputs, and reports their own number. The customer has no way to verify.

We built Koji's benchmark to be the thing we wished existed when we started.

## The corpus

The validation corpus is a public repository: 1,100 documents across 13 categories.

| Category | Documents | Real | Synthetic | Notes |
|----------|-----------|------|-----------|-------|
| sec_filings | 288 | 288 | 0 | EDGAR 10-K, 10-Q, 8-K, DEF 14A, S-1, 20-F, 6-K + amendments |
| invoices | 155 | 5 | 150 | Full schema coverage (line items, tax, currency) |
| insurance_claims | 152 | 22 | 130 | FEMA proof-of-loss, WC FROI, loss runs |
| contracts | 100 | 100 | 0 | Material contracts from SEC EDGAR |
| medical_records | 100 | 100 | 0 | MTSamples (15 specialties, CC0) |
| insurance_policies | 97 | 17 | 80 | Dec pages, endorsements, binders across 9 policy types |
| legal_filings | 61 | 61 | 0 | Court opinions (CourtListener, CC0) |
| insurance_certificates | 61 | 21 | 40 | COIs from .gov/.edu + synthetic |
| receipts | 52 | 52 | 0 | SROIE scanned receipts (real OCR) |
| irs_forms | 20 | 0 | 20 | Structured tax forms |
| adversarial | 11 | 0 | 11 | Blank docs, OCR noise, wrong-schema, stapled packets |
| multi_format | 3 | 3 | 0 | xlsx, docx, pptx |

Each document has three components:
1. **The document itself** — parsed markdown (the input to extraction)
2. **A schema** — YAML defining what fields to extract, with types and validation rules
3. **Expected output** — JSON with the ground-truth values for every field

The real documents come from public sources: EDGAR filings, state insurance department websites, SROIE dataset, government COI repositories. The synthetic documents are generated to cover specific failure modes — carrier letter-codes on insurance certificates, line-broken text on SEC cover pages, multi-policy COIs with per-policy additional insureds.

The mix matters. Real documents test whether the pipeline handles actual OCR artifacts, layout variations, and formatting inconsistencies. Synthetic documents test specific edge cases that real documents don't cover densely enough.

## How we measure

One command:

```bash
koji bench --corpus . --model openai/gpt-4o-mini
```

This runs every document through the extraction pipeline, compares the output to expected values, and reports per-category and per-field accuracy.

### Field-level accuracy

We measure at the field level, not the document level. If a document has 7 fields and the pipeline gets 6 right, that's 6/7 = 85.7% for that document. The category accuracy is the sum of correct fields divided by total fields across all documents in the category.

Field-level is more honest than document-level because it doesn't let one hard field drag down an otherwise perfect extraction. If `filing_date` is consistently tricky but the other 3 fields on SEC filings are always correct, the field-level metric shows 75% per document (3/4) rather than 0% (document has an error).

### Comparison rules

Extracted values are compared against expected values with normalization:

**Dates** normalize to YYYY-MM-DD. "April 10, 2026", "04/10/2026", "2026-04-10" all match.

**Numbers** strip currency symbols and formatting. "$1,000.00", "1000", "1,000" all match.

**Strings** use configurable fuzzy matching. A fuzzy threshold of 0.85 (85% character similarity) allows minor OCR errors and formatting differences without counting them as failures. Each schema sets its own threshold.

**Arrays** compare order-independently with nested field matching. A list of insurance policies matches if every expected policy has a corresponding actual policy with matching fields, regardless of array order.

**Nulls** are correct when the field genuinely isn't in the document. An SEC filing schema applied to a 10-K should return null for `period_meeting_date` (that's a DEF 14A field). Returning null is correct; returning a hallucinated date is a failure.

### What we don't measure

We don't measure parsing accuracy (is the OCR correct?). The benchmark inputs are pre-parsed markdown. If the OCR misread a digit, the extraction might be "correct" (it faithfully extracted the wrong text) but the end-to-end result is wrong. Parsing accuracy is a separate problem with separate benchmarks.

We don't measure latency in the accuracy number. A field that takes 30 seconds to extract but returns the right value counts the same as one that returns in 1 second. Latency is tracked separately.

We don't measure cost per field. The benchmark reports elapsed time and can be run against different models to compare cost-accuracy tradeoffs, but the accuracy number itself is model-agnostic.

## What the benchmark revealed

Current results across the full corpus (GPT-4o-mini):

| Category | Documents | Accuracy | Notes |
|----------|-----------|----------|-------|
| irs_forms | 20 | 100.0% | Structured forms, strong schema hints |
| multi_format | 3 | 100.0% | xlsx, docx, pptx via docling |
| insurance_policies | 97 | 99.2% | Rich hints, well-structured docs |
| sec_filings | 288 | 98.3% | EDGAR filings, standardized format |
| medical_records | 100 | 97.7% | MTSamples clinical transcriptions |
| adversarial | 11 | 96.7% | Intentionally adversarial inputs |
| legal_filings | 61 | 96.3% | Court opinions, minimal structure |
| insurance_claims | 152 | 95.7% | Mixed form types (FEMA, WC, loss runs) |
| invoices | 155 | 94.9% | Diverse layouts and formats |
| contracts | 100 | 90.8% | Long EDGAR material contracts |
| insurance_certificates | 61 | 90.2% | Complex nested arrays |
| receipts | 52 | 81.0% | OCR noise from scanned thermal prints |
| **Overall** | **1,100** | **96.1%** | **8 domains, 12 categories** |

### Where extraction fails

**OCR quality (receipts, 81.0%).** The SROIE receipt dataset contains scanned images of thermal-printed receipts — blurry, skewed, low-resolution. The extraction is often correct given the OCR output; the OCR output is often wrong given the original image. This is a parsing problem, not an extraction problem, but it shows up in the end-to-end number.

**Long complex documents (contracts, 90.8%).** Material contracts from SEC EDGAR filings can be 50+ pages with dense legal prose and minimal structural cues. The correct section for a field might be buried on page 80 with no heading that matches schema keywords. These documents stress-test both routing precision and extraction attention.

**Complex nested arrays (insurance certificates, 90.2%).** Certificates of insurance contain a table of policies, each with its own carrier, limits, dates, and additional insureds. Extracting this as a structured array requires the LLM to associate the right carrier with the right policy row and match limits to the correct coverage type. Even small misassociations count as field failures.

### The variance problem

Run the same benchmark twice and you'll get different numbers. We've seen the overall accuracy vary by 2-3 percentage points between runs — same code, same model, same documents. The sources:

1. **LLM non-determinism.** Temperature=0 reduces but doesn't eliminate variation. OpenAI has confirmed this.
2. **Rate limiting.** At 1,100 documents, the benchmark fires thousands of LLM calls. If the API rate-limits some of them, those extractions fail silently. We added retry with exponential backoff specifically to address this (it moved SEC filings from 93.7% to 99.2%).
3. **Timing-dependent behavior.** Some API calls timeout under load that succeed when the API is less busy. Our 300-second timeout is generous, but not infinite.

We report the accuracy from a clean run with retries and stable connectivity. The number represents the pipeline's capability, not the API's reliability on any given day.

## Why this matters

Document extraction is too important to ship untested. If your pipeline processes insurance claims that determine payouts, or SEC filings that inform investment decisions, or medical records that affect patient care — you need to know the accuracy before you deploy, and you need to know when it regresses.

A benchmark that runs on every engine change, against a public corpus with published expected outputs, makes accuracy a measurable property of the system rather than a marketing claim. It's the difference between "we think it works" and "we measured it at 96.1% across 1,100 documents, and here's the JSON to prove it."

The corpus is public. The benchmark tool is open source. The methodology is what you just read. If you're building document extraction and you want to measure honestly, you can start here.

```bash
git clone https://github.com/getkoji/corpus
koji bench --corpus corpus/ --model openai/gpt-4o-mini
```

The number you get is the number. No cherry-picking, no caveats, no fine print.

---

*Frank Thomas is the founder of [Koji](https://getkoji.dev), an open-source document extraction platform. The validation corpus is available at [github.com/getkoji/corpus](https://github.com/getkoji/corpus).*
