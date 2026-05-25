---
title: "Null Semantics: When \"Nothing\" Is the Right Answer"
description: "Every extraction system can pull values out of documents. The harder problem is knowing when a value isn't there — and handling that correctly."
date: 2026-05-18
author: "Frank Thomas"
tags: ["extraction", "methodology"]
---

Every extraction system can pull values out of documents. The harder problem is knowing when a value *isn't there* — and handling that correctly.

Most extraction tools treat null as a failure. The model couldn't find the value, so something went wrong. But in real document processing, null is often the correct answer. A 10-K filing doesn't have a `meeting_date` — that's a proxy statement field. A consultation note doesn't have an `admission_date` — the patient was never admitted. A certificate of insurance doesn't always have an `umbrella_policy` — not everyone carries umbrella coverage.

If your system can't distinguish "the field isn't in this document" from "the model failed to extract it," you're going to have a bad time. Either you flag every legitimate null as a failure (drowning operators in false alerts), or you ignore all nulls (missing actual extraction failures).

---

## The four states of a field

When you compare an extracted value against a ground-truth expected value, there are four possible states:

### 1. Both present, match -> correct extraction

Expected: `"2026-04-10"` -> Actual: `"April 10, 2026"` -> **Pass** (after date normalization)

The happy path. The field is in the document, the model found it, and the value matches.

### 2. Both absent -> correctly absent

Expected: `null` -> Actual: `null` -> **Pass**

The field genuinely isn't in this document, and the model correctly returned nothing. This is as valid as a correct extraction — the model understood the document well enough to know the information isn't there.

This matters more than people think. In a mixed-document pipeline (insurance policies, certificates, claims all flowing through the same schema), most documents won't contain most fields. A policy has a `policy_number`; a certificate has a `certificate_number`; a claim has a `claim_number`. Correctly returning null for the fields that don't apply is half the job.

### 3. Expected present, actual absent -> missed

Expected: `"Acme Corp"` -> Actual: `null` -> **Fail** (missing from actual)

The field is in the document, but the model didn't find it. This is the standard extraction failure — the model missed a value. Causes range from the value being in an unexpected location (deep in an endorsement, buried in a table) to the model running out of attention on a long prompt.

### 4. Expected absent, actual present -> hallucinated

Expected: `null` -> Actual: `"Acme Corp"` -> **Fail** (hallucinated)

The field is *not* in the document, but the model returned a value anyway. This is the dangerous one.

Hallucination in extraction is different from hallucination in chat. In chat, the model invents plausible-sounding facts. In extraction, the model invents plausible-sounding field values — often by borrowing values from similar fields, adjacent documents in a stapled packet, or its training data.

An insurance policy with no `umbrella_policy` field gets `"$5,000,000"` because the model saw a dollar amount somewhere and associated it with the field name. A consultation note with no admission date gets `"2026-03-15"` because there's a date on the document (the consultation date) and the model confused the two.

Hallucinated extractions are worse than missed extractions. A null value gets flagged for manual review. A hallucinated value looks correct and flows downstream — into a database, a report, a coverage determination — until someone notices the number doesn't match the source document. By then, decisions have been made on bad data.

---

## Why most benchmarks get this wrong

Standard extraction benchmarks only test states 1 and 3: is the value correct, or did the model miss it? They don't test state 2 (correctly absent) or state 4 (hallucinated) because they don't include test cases where the expected value is null.

This means a model that hallucinates on every null field — returning made-up values instead of nothing — scores the same as a model that handles nulls correctly. The benchmark doesn't penalize hallucination because it doesn't test for it.

Our benchmark includes explicit null test cases. The adversarial category is entirely about this:

- **Blank documents.** A mostly empty file with a header but no content. Every field should be null.
- **Wrong-schema documents.** An invoice processed with an insurance policy schema. Every field should be null — the document doesn't contain policy information.
- **Out-of-scope documents.** A recipe run through an SEC filing schema. A good model returns all nulls; a bad model finds "ingredients" in the `risk_factors` field because the words are vaguely similar.
- **Stapled packets.** Two different documents concatenated. Fields from document A should not be contaminated by values from document B.

These test cases exist because we've seen all of these failure modes in production. A customer uploads a certificate of insurance, but the PDF actually contains three stapled documents — a certificate, an endorsement, and a cover letter. Without null semantics, the model happily extracts the cover letter's date as the `policy_effective_date` and nobody catches it until an underwriter notices the date makes no sense.

---

## How we handle nulls

### In the schema

Fields declare whether they're required:

```yaml
fields:
  policy_number:
    type: string
    required: true    # must be present — null is a failure

  umbrella_policy:
    type: string
    required: false   # may be absent — null is acceptable
```

Required fields that come back null trigger a retry — the pipeline re-extracts with broadened context (more chunks) before accepting the null. Optional fields that come back null are accepted immediately.

### In the extraction prompt

The LLM is explicitly told that null is a valid response:

> If a field is not present in the document, return null for that field. Do not guess or infer values that aren't explicitly stated.

This instruction alone doesn't prevent hallucination (models are optimistic by nature), but its absence makes hallucination significantly worse. Without explicit null permission, the model will fill in every field with its best guess, because that's what instruction-following models are trained to do — answer the question, don't say "I don't know."

### In the comparison

Our comparison engine treats all representations of "no value" as equivalent:

- `null`
- `""` (empty string)
- `[]` (empty array)
- `{}` (empty object)
- Field omitted entirely

These all mean "no value" and compare as equal. An extraction that returns `{"policy_number": "ABC-123"}` with no `umbrella_policy` key matches an expected output of `{"policy_number": "ABC-123", "umbrella_policy": null}`. The absent key and the explicit null are the same thing.

This sounds trivial, but getting it wrong produces hundreds of false failures in a benchmark. Different LLMs represent "nothing" differently: GPT-4o tends to return `null`, Claude tends to omit the key, and some models return `""`. Without normalization, you'd report these as mismatches even though they all mean the same thing.

### In confidence scoring

A correctly absent field gets a confidence label, just like an extracted field:

- **correctly_absent**: the model returned null and the expected value is null — high confidence that the absence is intentional, not a failure.
- **missing**: the model returned null but the expected value is present — this is a failure, flagged for review.

The confidence system treats null as a first-class extraction result, not as an error code. An operator reviewing extractions can see which fields are confidently absent vs. which are missing.

---

## The hallucination detection pipeline

Returning null correctly is step one. Step two is catching hallucinations — values the model returned that aren't in the source document.

For every extracted value, we check whether the value (or a close variant) appears in the routed sections. A string value should appear as a substring. A number should appear in a dollar amount or a table cell. A date should appear in a date-formatted expression.

If the extracted value doesn't appear in any of the sections the field was routed to, it's flagged as potentially hallucinated. This isn't perfect — the model might have correctly inferred a value from context (e.g., computing a total from line items) — but for most fields, a value that doesn't appear in the source text is suspicious.

This source-grounding check catches the most dangerous hallucination pattern: the model extracting a value from the wrong section of a stapled document, or from a different field's context that happened to share chunks. The value is real (it exists in the document somewhere), but it's attributed to the wrong field. Without grounding, this looks like a correct extraction. With grounding, the mismatch between the value's location and the field's routed sections triggers a flag.

---

## What this means in practice

If you're evaluating extraction systems, ask these questions:

1. **Does the benchmark include null test cases?** If not, the accuracy number doesn't account for hallucination. A system that hallucinates on every absent field could still report 95%+ accuracy.

2. **Does the system distinguish "field not found" from "field not in document"?** If everything is just `null` with no context, operators can't prioritize their review queue.

3. **Does the system check values against the source text?** If the extracted value doesn't appear in the document, who catches it?

4. **What happens with mixed document types?** Upload an invoice to a policy extraction pipeline. Does it return all nulls (correct), or does it find an "insurer name" in the vendor field (hallucinated)?

Null handling isn't a feature. It's a correctness requirement. The documents your system processes in production will contain every combination of present and absent fields, across every combination of document types. If your extraction only works on the happy path — every field present, every value extractable — it works on the demo, not on the pipeline.

---

*Frank Thomas is the founder of [Koji](https://getkoji.dev), an open-source document extraction platform. The null semantics described here are implemented in Koji's comparison engine and tested against the adversarial category of the [validation corpus](https://github.com/getkoji/corpus).*
