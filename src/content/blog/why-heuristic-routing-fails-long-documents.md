---
title: "Why Heuristic Routing Fails on Long Documents"
description: "When a 120-page insurance policy goes through extraction, the AI sees fragments. If the router picks the wrong chunks, the AI can't extract what isn't in front of it."
date: 2026-05-14
author: "Frank Thomas"
tags: ["extraction", "routing"]
---

When a 120-page insurance policy goes through document extraction, the AI doesn't see the whole document. It sees fragments — chunks of text selected by a routing algorithm. If the router picks the wrong chunks, the AI can't extract what isn't in front of it.

For short documents this doesn't matter. For long documents, it's the difference between 95% and 50% accuracy.

---

## The routing problem

Large language models have context windows, but most documents worth extracting are too large to fit in a single prompt. A 120-page insurance policy is roughly 300,000 tokens of parsed text. Even with a 128K context window, you wouldn't want to send all of it — the model's attention degrades on long inputs, costs scale linearly with tokens, and most of the document is irrelevant to any individual field.

So the document gets chunked. Headings become section boundaries. A 120-page policy might produce 100-300 chunks, each a heading and its content. The extraction pipeline needs to decide: for each field in the schema (policy number, insured name, effective date, coverage limits), which chunks should the model see?

This is the routing problem. Get it right and the model extracts accurately from focused context. Get it wrong and the model either hallucinates from irrelevant text or returns null because the answer wasn't in the chunks it received.

## How heuristic routing works

The standard approach scores every chunk against every field using a mix of signals:

**Keyword matching.** The schema can declare that `policy_number` should look in chunks categorized as "declarations" and match patterns like `policy.?number` or `policy\s*:\s*[A-Z0-9]`. Chunks with keyword hits score higher.

**Position bias.** Fields like `insured_name` typically appear at the top of the document. Fields like `filing_date` appear near the signature block at the bottom. A linear position score gives top-of-document chunks a boost for top-biased fields and vice versa.

**Signal detection.** The pipeline detects structural signals in each chunk: does it contain dollar amounts? Dates? Key-value pairs? Tables? A field typed as `number` gets a boost from chunks with dollar amounts. A `date` field gets a boost from chunks with date patterns.

**Fuzzy name matching.** If no hints are provided, the router looks for the field name itself in chunk titles and content. A field named `total_premium` gets a boost from chunks containing "total premium."

After scoring, the router picks the top N chunks per field (default: 3) and sends them to the LLM for extraction.

## Where heuristics break down

On a 5-page invoice with 6 chunks, every chunk is within the top-3 cutoff for most fields. The heuristic doesn't need to be precise — even a mediocre scorer puts the right content in front of the model.

On a 120-page insurance policy with 300 chunks, the top-3 cutoff means each field sees 1% of the document. The scorer must be precise. And heuristics aren't.

The problem manifests in two ways:

**Front-loading bias.** Cover page fields (policy number, insured name, effective date) have strong keyword signals that appear early in the document. They score well because the keywords are concentrated. But fields that appear deep in the document — an endorsement modifying coverage limits on page 95, a condition on page 80, a signature date on the last page — compete with 297 other chunks. Their keywords are diluted across the document, and the position bias works against them.

The result: front-loaded fields extract reliably. Deep fields return null.

**Category bleed.** Schema authors can declare categories (`declarations`, `endorsements`, `coverage`) and restrict routing with `look_in` hints. But category classification is itself heuristic — keyword-based, applied per-chunk, with a configurable threshold. When a chunk contains keywords from multiple categories (an endorsement that references declaration values), it gets miscategorized. The field that should route to it can't see it because it's in the wrong category bucket.

## Measuring the gap

We benchmarked 97 insurance policy documents ranging from 2 to 335 chunks. Baseline accuracy with heuristic-only routing: 95.2%.

The 4.8% failure rate clustered in the longest documents. The 335-chunk Chubb BOP policy — a businessowner's package with declarations, coverage forms, endorsements, and conditions — was the worst case. Heuristic routing picked declaration chunks for almost every field, missing endorsement data entirely.

The per-field breakdown told the story:

| Field | Accuracy | Issue |
|-------|----------|-------|
| policy_number | 99% | Always on cover page, strong keywords |
| named_insured | 98% | Always on cover page, strong keywords |
| effective_date | 97% | Date signal + cover page position |
| each_occurrence_limit | 91% | Sometimes in endorsements, not just declarations |
| general_aggregate_limit | 89% | Same — endorsements modify the base value |
| insurer_name | 85% | Multi-insurer policies: name appears in different sections |

Fields with strong positional priors worked. Fields that require scanning deep into the document didn't.

## The two-pass approach

The fix is to ask the LLM which chunks contain which fields before starting extraction.

**Pass 1: Map.** Send the LLM a numbered list of chunk previews (title + first 400 characters of each) along with the list of schema fields. Ask it to return a JSON mapping: `{field_name: [chunk_indices]}`. This is a single LLM call with a compact prompt — chunk previews are much smaller than full chunk content.

```
## Document sections

  [0] DECLARATIONS: COMMERCIAL GENERAL LIABILITY...
  [1] SCHEDULE OF FORMS: The following forms apply...
  [2] COVERAGE FORM CG 00 01: COMMERCIAL GENERAL...
  ...
  [89] ENDORSEMENT CG 24 04: WAIVER OF TRANSFER...

## Fields to locate

  - policy_number (string): The policy number or identifier
  - each_occurrence_limit (number): Per-occurrence limit of liability
  - general_aggregate_limit (number): General aggregate limit

Return JSON mapping each field to the section indices that contain it.
```

The LLM reads the previews and returns: `{"policy_number": [0], "each_occurrence_limit": [0, 89], "general_aggregate_limit": [0, 2]}`. It knows the endorsement on chunk 89 modifies the occurrence limit because it can read the preview text — something keyword heuristics can't do.

**Pass 2: Extract.** Use the map's assignments to route each field to its chunks. The extraction prompts now contain the right content, regardless of where it appears in the document.

### When to engage (and when not to)

The map pass adds one LLM call. For a 5-page invoice, that's wasted cost — the heuristic router already picks the right 6 chunks. We only engage the map when the document has 50+ chunks, which is roughly 20+ pages of structured content. Below that threshold, heuristic routing runs alone.

### Merging, not replacing

An early version of this replaced heuristic routing entirely with the map's assignments. It improved long-document accuracy but regressed on medium-length documents — the map occasionally missed chunks that the heuristic scorer found via keyword patterns.

The production implementation merges both: the union of heuristic-selected chunks and map-selected chunks, deduplicated, ordered by position. The map can only add coverage. It can never narrow the chunk set below what heuristics would have provided.

This is a general principle worth stating: when you add an AI-powered step to a pipeline, design it as a supplement to deterministic logic, not a replacement. The AI is better at understanding content; the deterministic logic is better at not randomly dropping things.

## Results

| Category | Heuristic only | With section map | Delta |
|----------|---------------|-----------------|-------|
| Insurance policies | 95.2% | 98.4% | +3.2% |
| Short documents (<50 chunks) | Unchanged | Unchanged | 0% |

The improvement concentrates where it should — long documents where heuristic routing was forced to drop content. Short documents are unaffected because the map never engages.

The cost per long document: approximately $0.001 for the map LLM call. Negligible compared to the extraction calls that follow.

## Implications

Document extraction pipelines that chunk long documents and pick a fixed number of chunks per field have a structural accuracy ceiling. The ceiling gets lower as documents get longer. If your pipeline extracts well from 10-page invoices but struggles with 100-page contracts, the routing is the likely bottleneck — not the model, not the prompt.

The two-pass pattern (map then extract) generalizes beyond document extraction. Any pipeline that selects context for an LLM — RAG retrieval, agent tool selection, multi-document summarization — faces the same problem: heuristic selection works at small scale and degrades at large scale. An LLM-powered selection pass scales where heuristics don't, because it reads the content instead of pattern-matching against it.

The key design constraint: make it additive. Let the LLM expand the context window, not narrow it. When the AI and the heuristics disagree, include both. You pay a token cost for the extra context, but you never pay an accuracy cost for a missed chunk.

---

*Frank Thomas is the founder of [Koji](https://getkoji.dev), an open-source document extraction platform. The routing and section map code described here is open source in the [Koji repository](https://github.com/getkoji/koji).*
