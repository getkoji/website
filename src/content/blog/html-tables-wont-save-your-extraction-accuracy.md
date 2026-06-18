---
title: "HTML Tables Won't Save Your Extraction Accuracy"
description: "We tested four table encodings — markdown, HTML, JSON, and CSV — across three models and 232 documents. Re-encoding tables changed accuracy by amounts indistinguishable from noise. The only thing that moved was the token bill."
date: 2026-06-18
author: "Frank Thomas"
tags: ["extraction", "benchmarking", "llm"]
---

Our extraction pipeline parses documents to markdown before sending them to the model. Markdown renders tables as pipe-delimited rows — `| Date | Amount |` — and a reasonable worry is that pipe tables are lossy: column alignment gets fuzzy, wide tables wrap, and the model has to infer structure from punctuation. The proposed fix was to detect table-heavy documents and re-encode their tables as HTML `<table>` elements before extraction, on the theory that explicit `<tr>`/`<td>` structure is easier for the model to read.

It's a clean hypothesis. We tested it — and then tested three other encodings while we were at it. Across 232 documents and three models, re-encoding tables changed extraction accuracy by amounts indistinguishable from noise. The only thing that reliably moved was the token bill.

---

## The setup

We took the table-heavy documents from our open extraction benchmark — the ones where pipe-table rows make up at least 30% of the content — and built the same extraction prompt four times, changing **only** how the tables were encoded:

- **Markdown** — the pipe tables as parsed (the current default).
- **HTML** — each table rewritten as `<table><thead><tr><th>…</tr></thead><tbody><tr><td>…`.
- **JSON-rows** — each table as a JSON array of row objects, `[{"Date": "...", "Amount": "..."}]`.
- **CSV** — each table as comma-separated rows with a header line.

Everything else was held constant: same schema, same field list, same instructions, temperature 0. The only variable in the prompt is the table encoding. Each format got a one-line note telling the model how its tables were formatted, so no format was disadvantaged by surprise.

We ran all four formats through three models — **GPT-4o-mini**, **GPT-4o**, and **Claude Haiku 4.5** — and scored every result against the benchmark's ground truth with type-aware field comparison (date normalization, numeric tolerance, fuzzy string matching, order-independent arrays). The sample: **232 documents across 8 categories** (SEC filings, contracts, invoices, receipts, insurance claims/policies/certificates, IRS forms), stratified into three table-size buckets — 4–10 rows (29 docs), 11–30 rows (120), and 30+ rows (83) — so we could check whether big tables behave differently from small ones.

That's 2,784 extractions. Here's what came back.

## Re-encoding tables doesn't move accuracy

Field accuracy, by model and table format:

| Model | Markdown | HTML | JSON-rows | CSV |
|---|---|---|---|---|
| GPT-4o-mini | 92.45% | 92.71% | 86.05% | 92.51% |
| GPT-4o | 90.72% | 90.53% | 87.52% | 90.66% |
| Claude Haiku 4.5 | 91.17% | 91.17% | 89.19% | 91.04% |

Read it as deltas from markdown:

| Model | HTML | JSON-rows | CSV |
|---|---|---|---|
| GPT-4o-mini | +0.26 | **−6.40** | +0.06 |
| GPT-4o | −0.19 | **−3.20** | −0.06 |
| Claude Haiku 4.5 | +0.00 | **−1.98** | −0.13 |

Three findings, all consistent across models:

**HTML is a wash.** The accuracy delta versus markdown ranges from −0.19pp to +0.26pp. There is no detectable benefit to rewriting pipe tables as `<table>` elements. The hypothesis that explicit HTML structure helps the model read tables is just not borne out — the model parses pipe tables fine.

**JSON-rows actively hurts.** This was the surprise. The most "structured," machine-readable encoding was the *worst* in every case, by 2 to 6 points. Turning a table into an array of row objects repeats the column names on every row, inflating the input, and it strips the visual grid the model uses to associate a value with its column and row. The model does worse when you hand it the format a programmer would call cleanest.

**CSV ties markdown.** Within ±0.13pp for all three models. Same accuracy, plainer encoding.

## The "but big tables" objection, answered

The strongest case for HTML is that it should help most where pipe tables are most lossy — on large tables, where alignment drifts and rows wrap. So we split the results by table size. If HTML helps anywhere, it's the 30+ row bucket.

Accuracy delta vs markdown, 30+ row tables (83 docs):

| Model | HTML | JSON-rows | CSV |
|---|---|---|---|
| GPT-4o-mini | +0.36 | −5.75 | +0.18 |
| GPT-4o | −0.18 | −5.57 | +0.36 |
| Claude Haiku 4.5 | +0.18 | −5.20 | −0.17 |

HTML is still flat on big tables. JSON-rows actually gets *worse* on big tables (−5 to −6pp) — exactly where its per-row key repetition and lost alignment compound. The one place the HTML hypothesis predicted a win is the one place we can most confidently say there isn't one.

## What does move: the token bill

Re-encoding tables doesn't change accuracy, but it absolutely changes cost. Input-token overhead versus markdown:

| Model | HTML | JSON-rows | CSV |
|---|---|---|---|
| GPT-4o-mini / GPT-4o | +13.4% | −3.5% | −8.4% |
| Claude Haiku 4.5 | +8.0% | −6.8% | −11.1% |

HTML's `<td>…</td>` scaffolding is pure overhead — **8–13% more input tokens on every table-heavy extraction, for zero accuracy gain.** That's a recurring tax with no return. JSON-rows is worse than its input number suggests, too: on GPT-4o-mini it nearly *doubled* output tokens (the model echoes more structure back), making it both the least accurate and among the most expensive.

CSV is the quiet winner on the only axis that moved — it matches markdown's accuracy at 8–11% fewer input tokens.

## What we did with this

The proposed HTML conversion shipped nowhere. It was a recurring token tax dressed up as an optimization, and the experiment that was supposed to justify it killed it instead. Markdown — what the pipeline already produces — sits at the top of the accuracy range for all three models, so the default needed no defending. The one change worth considering is CSV for table-heavy documents: identical accuracy, a real token saving. JSON-rows we'll never reach for; "more structured" turned out to mean "harder to extract from."

The broader lesson is the cheap one to forget: a plausible preprocessing step is still a hypothesis, and the way you find out whether it helps is to hold everything else constant and measure. This one cost about \$18 in API calls to settle. The version that ships without measuring costs 13% more, forever.

## Caveats

This is a single extraction step with everything but the table encoding held fixed — not the full production pipeline, which adds routing, context chunks, and gap-fill retry. Absolute accuracy here is lower than production; the *relative* comparison between formats is what we're reporting, and that should hold. We tested three models; a much weaker open-weight model might lean on explicit structure more (or choke on it harder), which we'd test before generalizing. Ground truth is the benchmark's, scored with a fuzzy threshold per schema. And 232 documents is enough to call a 2–6pp effect confidently but not to split hairs under ~0.5pp — which is exactly why we're calling HTML and CSV "ties," not winners.

---

*Koji is an open-source document extraction platform. The benchmark corpus and evaluation tooling are at [github.com/getkoji/corpus](https://github.com/getkoji/corpus). For why GPT-4o-mini beats GPT-4o here too, see [Bigger Models Don't Extract Better](/blog/model-size-extraction-accuracy).*
