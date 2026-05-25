---
title: "Schema-Driven Extraction: Configuration Over Code for Document AI"
description: "Most extraction approaches rely on prompt engineering. Schema-driven extraction replaces the hope with a contract — typed fields, validation rules, and routing hints in a YAML file."
date: 2026-05-06
author: "Frank Thomas"
tags: ["extraction", "architecture"]
---

Most document extraction approaches rely on prompt engineering — write natural language instructions, send them with the document, hope the model follows them. It works in demos. It breaks in production.

Schema-driven extraction replaces the hope with a contract: typed fields, validation rules, routing hints, and confidence thresholds, all declared in a YAML file that the pipeline interprets at every stage. The schema isn't just a prompt — it's the specification that the entire system is built to satisfy.

---

## Three ways to extract data from documents

### Prompt-only

The simplest approach. Write a prompt:

```
Extract the following from this invoice:
- Invoice number
- Date
- Total amount
- Line items (description, quantity, unit price, amount)

Return as JSON.
```

Send it with the document text. Parse the JSON response. Done.

This works for demos and one-off scripts. It breaks in production for predictable reasons:

**No types.** The model returns "total_amount": "$1,234.56" sometimes and "total_amount": 1234.56 other times. Your downstream system expects a number. You write a parser. Then you find it also returns "total_amount": "1,234.56 USD" and "total_amount": "one thousand two hundred thirty four dollars." You write more parsers.

**No validation.** The model returns a date of "2026-13-45." Your code ingests it. A customer notices three weeks later. You add a date validator. Then the model starts returning dates as "Q1 2026" for some documents and your validator rejects them even though the value is technically present.

**No confidence.** Every field comes back with equal certainty. The model says the invoice number is "INV-12345" with the same tone it says the vendor name is "Acme Corp" — even when it hallucinated the vendor name from a similar document it saw in training. You have no way to distinguish high-confidence extractions from guesses without manually reviewing every document.

**No routing.** The entire document goes into the prompt. For a 5-page invoice, fine. For a 120-page contract, you exceed the context window. You chunk the document and pick chunks to send — but how? Randomly? First N? You're back to building infrastructure.

The prompt-only approach doesn't scale because it puts all the intelligence in one place (the prompt) and none in the pipeline around it.

### RAG-based

The retrieval-augmented generation approach adds a layer: embed the document chunks, store them in a vector database, retrieve the most relevant chunks for each query, then prompt against the retrieved context.

This solves the routing problem — sort of. Cosine similarity retrieval finds chunks that are semantically close to your query. But "semantically close" isn't the same as "contains the answer."

A chunk about "general aggregate limit" is semantically similar to a query for "general aggregate limit." But the chunk that contains the actual dollar amount might be titled "Schedule of Limits" and contain a table of numbers with no mention of the phrase "general aggregate." The semantic retrieval misses it because the text doesn't match, even though the value is right there.

RAG also inherits all of prompt-only's problems: no types, no validation, no confidence. You've improved retrieval but the extraction itself is still unstructured.

### Schema-driven

A schema-driven approach declares what to extract, how to find it, and what correct output looks like:

```yaml
name: insurance_policy
description: Policy declarations page extraction

categories:
  keywords:
    declarations: ["declarations", "policy summary", "dec page"]
    coverage: ["limits of insurance", "each occurrence"]
    endorsements: ["endorsement", "schedule of endorsements"]

fields:
  policy_number:
    type: string
    required: true
    hints:
      look_in: [declarations]
      patterns: ["policy.?number", "policy\\s*:\\s*[A-Z0-9]"]

  effective_date:
    type: date
    hints:
      look_in: [declarations]
      patterns: ["effective", "inception", "policy period"]
      signals: [has_dates]

  each_occurrence_limit:
    type: number
    hints:
      look_in: [coverage, declarations]
      patterns: ["each occurrence", "per occurrence"]
      signals: [has_dollar_amounts]
```

The schema tells the pipeline:
- **What to extract** — named fields with declared types
- **Where to look** — category restrictions and keyword patterns that guide chunk routing
- **What signals matter** — structural hints (this field is near dollar amounts, this one is near dates)
- **What's required** — which fields must be found vs. which can be null
- **What the valid values are** — enums, ranges, cross-field constraints

The pipeline uses every piece of this at different stages. The document mapper classifies chunks into categories using the schema's keywords. The router scores chunks per-field using the schema's hints. The extractor uses the field types and descriptions to prompt the LLM. The validator checks the output against the schema's type constraints. The confidence scorer uses the field's type to determine what "provenance" means (a number that appears in the source text vs. a number the model computed).

No single stage is dramatically smarter than the prompt-only approach. The improvement comes from the accumulation of small, correct decisions across the entire pipeline — each one guided by the schema.

## Why schemas win at scale

### Testable

Every schema change runs against a ground-truth corpus before deployment. The benchmark command processes every document, compares output to expected values, and reports per-field accuracy. If a schema change drops accuracy, you know before it reaches production.

This is impossible with prompt-only extraction. You can't regression-test a prompt because the output is unstructured — there's no expected shape to compare against. With a schema, the expected shape is the schema itself.

### Versionable

Schemas have version history. Version 12 of the invoice schema added line item support. Version 13 tightened the date format. Version 14 added a fuzzy match for vendor names. Each version is a committed artifact with a message explaining what changed and why.

When extraction quality regresses, you diff the schema versions. When a customer reports a problem, you check which schema version their pipeline is deployed on. When you want to roll back, you deploy the previous version.

### Shareable

A schema for "ACORD 25 Certificate of Insurance" works for every ACORD 25, not just one customer's documents. The category keywords, field hints, and validation rules encode domain knowledge about how ACORD 25 forms are structured — knowledge that took hours of testing to develop and would take the next customer the same hours to rediscover.

Published schemas become shared infrastructure. A community of users improving the same schema produces a better result than any single team could alone. The hints get refined, edge cases get covered, the corpus grows, and the accuracy improves for everyone using it.

### Debuggable

When a prompt-only extraction fails, the debugging process is: read the prompt, read the document, read the output, guess what went wrong, modify the prompt, try again. There's no intermediate state to inspect.

When a schema-driven extraction fails, the routing plan shows exactly which chunks each field received, why those chunks were selected (hint match, signal detection, keyword score), and what the LLM returned for each extraction group. You can see that `each_occurrence_limit` was routed to chunks 0 and 3 (declarations) but the actual value was in chunk 89 (an endorsement that modified the limit). The fix is clear: add `endorsements` to the field's `look_in` list.

The pipeline's decision-making is transparent because the schema makes it structured. Every routing decision, every validation check, every confidence score traces back to a declared property of the schema.

## Configuration is the moat

The technical argument for schemas is about quality: types, validation, routing, confidence, testability. But the strategic argument is about accumulation.

Every hour a team spends tuning a schema — adding hints, expanding the corpus, refining validation rules — makes their extraction more accurate. That investment compounds. After six months, a team's invoice schema handles 50 edge cases that a fresh prompt-only setup doesn't know about. After a year, their insurance policy schema has been tested against 200 real documents from 15 different carriers.

This configuration investment doesn't transfer to other platforms. The hints are Koji-specific. The corpus is tied to the schema format. The validation rules reference the schema's field names and types. Switching to a different extraction tool means rebuilding all of it from scratch.

This is the right kind of lock-in: the customer stays because their configuration has genuine value, not because the vendor made it technically difficult to leave. The schemas are YAML files in a git repository. The customer owns them completely. They stay because the schemas work, not because they're trapped.

## What this means for the field

Document extraction is not a model problem. GPT-4o, Claude, Gemini, Llama — they all extract competently when given the right context. The model is a commodity input. What differentiates extraction quality is everything around the model: how chunks are selected, how output is validated, how confidence is measured, how edge cases are handled.

Schemas encode that "everything around the model" in a portable, testable, shareable format. They turn extraction from an art (prompt engineering, trial and error, vibes) into an engineering discipline (typed interfaces, regression tests, version control).

The best prompt in the world, applied to the wrong chunks, with no validation and no confidence scoring, loses to a mediocre prompt applied to the right chunks with type checking and provenance verification. Infrastructure beats inspiration.

---

*Frank Thomas is the founder of [Koji](https://getkoji.dev), an open-source document extraction platform. Koji schemas are YAML files — the examples in this post are from production schemas in the [Koji corpus](https://github.com/getkoji/corpus).*
