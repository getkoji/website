---
title: "Rate Limits, Retries, and the Hidden Accuracy Killer in LLM Pipelines"
description: "We spent weeks investigating a 6% accuracy variance. The root cause wasn't the model or the prompts — it was silent HTTP 429 errors treated as 'field not found.'"
date: 2026-05-16
author: "Frank Thomas"
tags: ["extraction", "infrastructure"]
---

We spent weeks investigating a 6% accuracy variance in our document extraction benchmarks. The root cause wasn't the model, the prompts, or the routing. It was silent HTTP 429 errors from OpenAI that our pipeline treated as "field not found."

This is the story of how we found it, why it matters, and what we changed.

---

## The mystery

Koji extracts structured data from documents — insurance policies, SEC filings, invoices, medical claims. We have a corpus of 653 documents with ground-truth expected outputs, and we benchmark every engine change against it before merging.

The numbers wouldn't stabilize:

| Run | Accuracy |
|-----|----------|
| 1 | 94.5% |
| 2 | 89.8% |
| 3 | 88.8% |
| 4 | 91.6% |

Same 653 documents. Same model (gpt-4o-mini). Same schemas. Same code. Six percentage points of variance between runs.

Our first theory was LLM non-determinism. Even at `temperature: 0`, OpenAI's API isn't fully deterministic — they've acknowledged this publicly. We figured the model was occasionally missing fields on borderline cases, and the variance was just the random distribution of those misses across runs.

We were wrong.

## The investigation

We started by running the failing documents individually. A 10-Q filing from KB Home that returned all nulls in the benchmark? Extracted perfectly when run alone. Every field found, correct values, medium-to-high confidence.

We ran it again. Perfect. Again. Perfect.

Then we embedded it back in the full 653-document benchmark. It failed.

We added same-chunk retry logic — when a required field comes back null, re-run extraction on the identical chunks before trying anything else. The idea was that if LLM non-determinism was the cause, a second attempt with the same input would often succeed.

It helped. Marginally. The accuracy variance shrank from 6 points to about 4. But the pattern was wrong for non-determinism: failures clustered in time, not by document. The middle of a benchmark run had more failures than the start or end. Random non-determinism wouldn't do that.

## The cause

We checked the Docker logs of the extract service.

```
[koji-extract] Group ['period_fiscal_year_end', 'period_date_of_report'] error:
  Client error '429 Too Many Requests' for url
  'https://api.openai.com/v1/chat/completions'

[koji-extract] Group ['filing_date'] error:
  Client error '429 Too Many Requests'

[koji-extract] Gap fill for filing_date error:
  Client error '429 Too Many Requests'
```

Rate limiting. Running 653 documents sequentially fires hundreds of LLM calls. The API has per-minute rate limits. Once you exceed them, requests get rejected with HTTP 429. Our extraction pipeline had no retry logic — a 429 was treated as a fatal error, and the extraction returned an empty result.

An empty result looks exactly like "the field isn't in the document." The pipeline records it as a null extraction with `not_found` confidence. The benchmark counts it as a field failure. Nothing in the output distinguishes "the LLM couldn't find this field" from "the LLM was never asked because the API rejected the request."

The clustering pattern made sense now. The benchmark starts with small documents (adversarial category, 11 docs) that process quickly. By the time it reaches the larger categories — insurance policies, SEC filings — it's firing requests at a sustained rate that triggers the rate limiter. The middle of the run fails; the end recovers as the rate limit window resets.

## The numbers

One benchmark run hit **355 rate-limit retries** before we added the fix. That's 355 LLM calls that silently failed and were recorded as extraction failures. On a corpus where the total field count is 3,961 — that's nearly 9% of fields potentially affected by a single infrastructure issue.

The smoking gun was a run that reported **6.0% accuracy** — 23 out of 383 fields on SEC filings. Nearly every document returned all nulls. The logs were wall-to-wall 429s. It wasn't an extraction quality problem. It was an HTTP client problem.

## The fix

Three lines of logic, not counting the retry utility:

```python
_RETRY_STATUS_CODES = {429, 502, 503, 529}
_MAX_RETRIES = 3
_BASE_DELAY = 2.0  # seconds
```

When the LLM API returns a retryable status code, wait and try again with exponential backoff: 2 seconds, then 4, then 8. Three attempts before giving up.

We applied this to the `generate()` and `chat()` methods of the OpenAI provider — the two paths that make outbound LLM calls. Every extraction group, every gap-fill retry, every section-map call now retries on rate limits instead of failing silently.

The result on SEC filings:

| Before | After |
|--------|-------|
| 93.7% (359/383 fields) | 99.2% (380/383 fields) |

That 5.5% improvement isn't better extraction. It's the same extraction actually completing instead of being silently killed by the API.

A clean 20-document batch with no rate limiting: 100% accuracy. The extraction quality was always there. The infrastructure was hiding it.

## What this means for LLM pipelines generally

If you're building anything that makes LLM API calls at volume — extraction, classification, summarization, agents — you probably have this bug. Here's what to check:

**1. Never treat HTTP errors as application-level results.**

An API error is not "the model couldn't find the answer." It's "the model was never asked." Your pipeline needs to distinguish between:
- The LLM ran and returned null -> genuine not-found, record as such
- The LLM call failed -> retry, and only record a result after the call succeeds or all retries exhaust

If your code catches exceptions from the HTTP client and returns an empty dict, you have this bug.

**2. Your accuracy metrics are only as reliable as your infrastructure.**

We were measuring our API client's resilience, not our extraction quality. A benchmark that doesn't retry on transient errors measures something — but not what you think it measures. If your accuracy numbers fluctuate between runs and you blame "LLM non-determinism," check your logs first.

**3. Log the HTTP layer, not just the application layer.**

Our extraction logs showed "field not found" for the failing fields. Correct — the field wasn't found, because the call that would have found it never completed. We only discovered the root cause by checking the HTTP response codes in the Docker logs. If we'd been running in a managed environment without access to those logs, we might still be chasing "non-determinism."

**4. Test at production throughput, not demo scale.**

Our 20-document smoke tests never hit rate limits. The problem only manifested at 100+ documents. If your test suite runs 10 examples and your production runs 10,000, you're not testing what matters. Rate limits, connection pools, memory pressure, timeouts — these are all scale-dependent. Your benchmark needs to run at a scale that triggers the same failure modes your production traffic will.

**5. Retry is not optional.**

Every LLM provider has rate limits. Every provider has transient errors (502, 503). Every provider has maintenance windows. If your pipeline treats these as permanent failures, your accuracy has a ceiling set by your provider's reliability, not by your extraction quality.

Three retries with exponential backoff. It's not clever. It took us embarrassingly long to add it. But it moved our accuracy more than any prompt optimization, routing improvement, or model upgrade we'd tried in weeks.

---

*Frank Thomas is the founder of [Koji](https://getkoji.dev), an open-source document extraction platform. The benchmarking corpus referenced in this post is [public](https://github.com/getkoji/corpus).*
