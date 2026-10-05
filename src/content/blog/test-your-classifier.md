---
title: "Test Your Document Classifier Like You Test a Model"
description: "A document classifier decides which schema a document gets. One wrong route and the right model extracts against the wrong schema. Here's why Koji classifiers now have a corpus, a backtest, a confusion matrix, and a promotion gate that checks each class you name."
date: 2026-08-06
author: "Frank Thomas"
tags: ["classification", "routing", "validation", "pipelines"]
---

Most of the attention in document extraction goes to the extraction step: the schema, the prompt, the model, the field that keeps coming back null. The step in front of it gets very little.

That step is the classifier. Before a pipeline can extract anything, something has to decide *what kind of document this is*: invoice, purchase order, contract, medical record. In a Koji pipeline that decision is a `classify` step, and its label picks which edge the document takes, which picks the extract step, which picks the schema.

So a classifier error doesn't look like a classifier error. A contract that gets routed as an invoice still runs a good model with a well-tuned schema. It's just the wrong schema. You get an invoice-shaped record with no invoice number, no line items, no total, and a lot of nulls. The extraction looks broken. The cause is upstream, and nothing points there.

We've been treating classifiers as a config file you tweak until the routing seems right. That isn't enough. A classifier is a model, and you should test it like one.

---

## The average hides the class you care about

Here's the failure mode that made us build this. You have a classifier with four classes. Purchase orders keep getting routed as invoices, because the two share vocabulary like "total," "qty," "unit price," and "bill to." So you widen the `purchase_order` keywords. You re-run your test documents and overall accuracy goes from 87% to 91%. You ship it.

What the 91% doesn't tell you is that the wider keywords now match invoices too. Purchase-order recall went up a lot, invoice recall went down a little, and the average went up. If invoices are most of your volume, or the ones a downstream system depends on, you just shipped a regression and the headline number said it was an improvement.

This isn't a hypothetical shape. It is how tuning goes whenever classes share language: widen one class and you take documents from its neighbor. An aggregate accuracy number is a weighted blend of every class's behavior, and it can rise while a class you care about falls.

So the unit you measure has to be the class, not the corpus.

---

## A corpus, a backtest, and a matrix

A Koji classifier can now hold a **corpus**: documents labelled with the class they *should* get. It works the same way a schema holds ground-truth documents. The label is one of the classifier's released class ids, or `unknown`, which means "this document should fall through." That's a real assertion worth testing, especially for a classifier configured with `on_unknown: reject`.

Corpus documents live in a project-level pool shared with schema corpora. A PDF you already uploaded as extraction ground truth can be labelled for a classifier by `document_id` without uploading it again.

From the CLI:

```bash
# label some documents
koji classify corpus add inbound_docs invoice ./samples/invoices/*.pdf
koji classify corpus add inbound_docs purchase_order ./samples/pos/*.pdf

# backtest the released version against the corpus
koji classify validate inbound_docs

# or pin a specific version, and exit non-zero if anything regressed vs. the previous run
koji classify validate inbound_docs --version v1.2.0 --check
```

The backtest sends every labelled document through `classifyWithConfig`, the same cascade the standalone classify endpoint and the pipeline `classify` step use. A backtest and a production route can't disagree about how a document gets classified. By default it runs the **released** version, the one production is routing with. For a large corpus it fans out one job per document, so corpus size never runs into a request timeout.

What comes back isn't one number. It's the overall accuracy, per-class precision, recall, and F1, and a **confusion matrix**. Here's an illustrative one for the candidate above (made-up numbers, rows are the expected class, columns are the predicted class):

| expected ╲ predicted | invoice | purchase_order | contract | medical_record | unknown |
|---|---:|---:|---:|---:|---:|
| **invoice** | **35** | 5 | · | · | · |
| **purchase_order** | 1 | **19** | · | · | · |
| **contract** | · | · | **28** | · | 2 |
| **medical_record** | · | · | · | **9** | 1 |

The diagonal is what you got right. Everything off the diagonal is a specific, fixable mistake. "Accuracy 91%" tells you nothing about what to change. "Five invoices predicted as purchase orders" tells you exactly what to tighten: the `purchase_order` keywords that also match invoices, or an `exclude_keywords` entry that rules out `purchase_order` when an invoice-only phrase appears. With more than two classes, which class a document was confused *with* is the useful output.

The result also includes a tier histogram and escalation rate: the share of documents that needed the paid LLM or vision tiers instead of the free metadata and keyword tiers. It also reports **flips** against the previous run, each document marked fixed, regressed, or churned (wrong before, wrong now, but with a different label). The dashboard has the same thing as **Corpus** and **Validate** tabs on the classifier page.

---

## Gate promotion on the classes you name

Visibility helps, but only if someone reads it. The second half is making the regression *blocking*.

`koji classify promote` takes a regression gate. It compares the candidate's latest backtest against the live release's latest backtest, class by class:

```bash
# refuse if ANY class's recall or precision dropped vs. the live release
koji classify promote inbound_docs --require-no-regressions

# refuse only if these named classes regressed
koji classify promote inbound_docs --must-not-regress invoice --must-not-regress contract

# absolute floors, regardless of what the live release scored
koji classify promote inbound_docs --min-recall invoice=0.95 --min-precision contract=0.9
```

Run the earlier example through `--must-not-regress invoice`. The live release got 38 of 40 invoices right and the candidate gets 35, so invoice recall drops from 95% to 88%. The promotion is refused, and the refusal names the class and the numbers (output illustrative):

```
✗ promotion blocked — inbound_docs would regress:
  • invoice recall 95% → 88%

Fix the regression, re-validate, and promote again — or `koji classify release` to bypass the gate.
```

The 91% headline never comes up. The gate doesn't look at the average at all.

A few design decisions are worth stating:

- **"Regressed" means any drop.** A guarded class whose recall or precision is strictly lower than the baseline blocks the promotion. There's no tolerance beyond float slack. If that's too strict for a small corpus where one document moves a class by several points, use an absolute floor (`--min-recall`) instead of a no-regression rule.
- **No evidence, no pass.** If you ask for a gate and the candidate has no completed backtest, the promotion is refused, not passed. A gate that silently passes when it couldn't evaluate is worse than having no gate.
- **The gate is opt-in, and the bypass is explicit.** `promote` with no gate flags promotes. `koji classify release` releases directly and skips the candidate and backtest loop by design. Both paths exist, and both say what they are.
- **A first release can't regress.** With no live release to compare against, only absolute floors apply.

The same gate is on the API: `POST /api/classifiers/{slug}/promote` with `requireNoRegressions`, `mustNotRegress`, `minRecall`, and `minPrecision`. A refusal is a `409` that lists each blocked class with before and after values.

---

## Labeling is the real cost, so review instead of type

None of this matters if nobody builds the corpus, and labeling a few hundred documents from scratch is where most backtests die.

**Bootstrap** does the first pass. It runs the classifier at `max_tier: 4`, the most thorough and most expensive cascade, over the project's unlabelled pool documents and writes each result as a **draft** label. Labeling becomes reviewing a list:

```bash
koji classify corpus bootstrap inbound_docs --limit 25
koji classify corpus approve inbound_docs scan_0142.pdf
koji classify corpus approve inbound_docs scan_0143.pdf --label contract
```

Drafts are never scored until a person approves them, and agent-proposed rows are marked `authored_via_agent` so an audit can tell a machine's guess from a human's confirmation. The intended loop: the expensive configuration proposes labels, a person confirms them, and you then tune a *cheaper* configuration until it matches that ground truth without regressing a class.

---

## "Unknown" vs. "never looked"

One last detail, because it bites people debugging a pipeline. A `classify` step that returns `unknown` sends the document down the pipeline's default route. That can mean two very different things, and the result's `method` field separates them:

- `method: "unknown"`: the classifier read the document and couldn't decide. The result carries a `reason` naming which tiers couldn't run and why, such as no text layer or the vision tier not allowed by `max_tier`.
- `method: "no_classifier"`, `"no_version"`, or `"no_file"` (and `"no_provider"` in a pipeline test run): the classifier **never looked**. The slug didn't resolve, the pinned version didn't exist, the document bytes weren't there, or no model provider was reachable.

Both carry the label `unknown` and route the same way. Only `method` tells "this document is ambiguous" apart from "this pipeline is misconfigured." Score routing without checking it, and a broken classifier reference looks like a classifier that's bad at its job.

---

## Why bother

Classification is the cheapest step in a document pipeline and the one whose mistakes cost the most downstream, because they show up as extraction failures. A misrouted document doesn't raise an error. It produces a confident, wrong-shaped record.

The tools to keep that from happening already exist in ML practice: a held-out labelled set, a per-class breakdown, a confusion matrix, and a release that can't ship if it breaks a class you said mattered. Koji classifiers now have all of them. Label the documents, backtest the change, read the off-diagonal, and gate the promotion on the classes you can't afford to lose.
