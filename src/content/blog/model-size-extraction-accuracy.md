---
title: "Bigger Models Don't Extract Better"
description: "We tested GPT-4o-mini, GPT-4o, Llama 3 8B, and Llama 3 70B on 165 documents. GPT-4o is worse than GPT-4o-mini at structured extraction — and we found out why."
date: 2026-05-29
author: "Frank Thomas"
tags: ["extraction", "benchmarking", "models"]
---

We tested four LLMs on 165 documents across 13 categories: GPT-4o-mini, GPT-4o, Llama 3 8B, and Llama 3 70B. The results surprised us.

---

## The expectation

Bigger models should extract better. They have more parameters, more training data, and better instruction following. If GPT-4o-mini gets 86% accuracy on document extraction, GPT-4o should get 90%+. And Llama 70B should crush Llama 8B.

Half of that was right.

## The results

| Model | Parameters | Accuracy | Null rate | Cost/1K docs |
|-------|-----------|----------|-----------|-------------|
| GPT-4o-mini | ~8B (est.) | **86.3%** | 20.8% | ~$3 |
| GPT-4o | ~200B (est.) | 84.0% | 25.4% | ~$30 |
| Llama 3 8B | 8B | 63.1% | 28.7% | ~$0 (local) |
| Llama 3 70B | 70B | 73.4% | 26.2% | ~$0 (local) |

Within Llama, scaling works as expected: 70B is +10.3pp better than 8B. Bigger model, more capable, higher accuracy.

Within OpenAI, scaling goes **backwards**: GPT-4o is -2.3pp worse than GPT-4o-mini. The larger, more expensive model extracts less accurately than the smaller one.

## Why GPT-4o is worse

GPT-4o returns null more often. On 917 fields across 165 documents, GPT-4o returned null for 25.4% of fields compared to GPT-4o-mini's 20.8%. That 4.6pp null gap accounts for most of the accuracy difference — GPT-4o isn't extracting wrong values, it's declining to extract at all.

The conservatism isn't uniform. It concentrates on specific field types:

| Field type | GPT-4o-mini | GPT-4o | Gap | What happens |
|-----------|------------|--------|-----|-------------|
| **Array** | 77.3% | 65.3% | **-12.0pp** | Complex structured output — GPT-4o struggles most |
| **String** | 83.6% | 79.8% | -3.8pp | Free-text fields — higher null rate |
| **Enum** | 83.6% | 86.3% | **+2.7pp** | Constrained choices — GPT-4o is actually better |
| **Date** | 87.2% | 87.2% | 0.0pp | Identical — unambiguous extraction |
| **Number** | 97.9% | 97.9% | 0.0pp | Identical — unambiguous extraction |

GPT-4o struggles on open-ended fields (arrays, free-text strings) but matches or beats GPT-4o-mini on constrained fields (enums, numbers, dates). The model seems to be more cautious when the output space is large and more decisive when it's constrained.

## We tested three hypotheses

**1. Is it prompt compliance?** We removed the "return null if not present" instruction from the prompt, forcing both models to always extract something.

Result: both models got **worse**, not better. GPT-4o-mini dropped 2.0pp, GPT-4o dropped 2.4pp. The nulls were mostly correct — forcing the models to guess produces hallucinations. And the gap between models persisted even without the null instruction (-2.7pp).

**2. Is it temperature?** We ran GPT-4o at temperature 0, 0.3, and 0.7.

Result: higher temperature made accuracy **worse** (84.0% → 83.0% → 82.6%) without reducing the null rate. The model isn't "choosing the safe response at low temperature" — it genuinely doesn't have the answer.

**3. Is it a scaling phenomenon?** We ran Llama 3 8B and 70B on the same documents.

Result: Llama 70B is +10.3pp **better** than 8B, with improvements across every field type. The "bigger is worse" pattern is OpenAI-specific, not a general scaling property. Whatever makes GPT-4o more conservative than GPT-4o-mini is in their training or fine-tuning, not in model scale itself.

## What this means for production

**Don't assume the most expensive model is the best for extraction.** GPT-4o costs ~10x more than GPT-4o-mini per token. On our benchmark, you pay more for lower accuracy. The assumption that "use the biggest model available" works for chat but not for structured extraction.

**Test models on your specific extraction task before choosing.** The accuracy difference varies dramatically by field type. If your schema is mostly enums and numbers, GPT-4o might be fine. If it's heavy on arrays and free-text strings, GPT-4o-mini is likely better.

**Local models are viable for some categories.** Llama 3 70B at 73.4% isn't competitive with GPT-4o-mini at 86.3%, but the gap is closing. On structured forms (IRS 1099s), Llama 70B hits 100% — identical to GPT-4o-mini. For categories with rigid structure and unambiguous fields, a local model running on-premise may be good enough, at zero marginal cost.

**The null rate is the diagnostic.** If a model is returning null on fields you know are present, it's being too conservative for your use case. Compare null rates across models on a sample of your documents before committing to one. A model with a 25% null rate is declining to extract a quarter of your fields.

## The cost-accuracy frontier

| Model | Accuracy | Cost/1K docs | Accuracy/$ |
|-------|----------|-------------|-----------|
| GPT-4o-mini | 86.3% | ~$3 | 28.8%/$ |
| GPT-4o | 84.0% | ~$30 | 2.8%/$ |
| Llama 3 70B | 73.4% | ~$0 | ∞ |
| Llama 3 8B | 63.1% | ~$0 | ∞ |

GPT-4o-mini is the Pareto-optimal choice for API-based extraction: highest accuracy at the lowest cost. GPT-4o is dominated — lower accuracy, higher cost. The local models win on cost but lose on accuracy, making them situationally useful for specific categories.

## Caveats

This benchmark uses a simplified extraction pipeline (chunk → route → extract) without production optimizations like document header context, gap-fill retry, or dependency-ordered extraction. The absolute accuracy numbers are lower than what a production pipeline achieves (~96%). The relative comparison between models should hold, but the gap between local and API models may narrow with pipeline optimizations.

The test set is 165 documents across 13 categories — large enough for aggregate trends but too small for per-category statistical significance. The Llama models were run locally on a MacBook Pro with 128GB RAM.

We tested two model families and four model sizes. The finding that "bigger is worse" is specific to OpenAI's models and should not be generalized to all model families without further testing.

---

*Frank Thomas is the founder of [Koji](https://getkoji.dev), an open-source document extraction platform. The benchmark corpus is available at [github.com/getkoji/corpus](https://github.com/getkoji/corpus).*
