---
title: "Schema TDD: Building Document Extraction Without Opening a Browser"
description: "Schema development isn't a configuration task — it's an engineering discipline. Here's how an iterative push-extract-inspect loop gets you to 96% accuracy in hours, not weeks."
date: 2026-06-05
author: "Frank Thomas"
tags: ["extraction", "schemas", "workflow"]
---

Most people think building a document extraction pipeline is a one-shot exercise. Define the fields you want, point the model at a PDF, done. It works for the first document. It falls apart by the tenth.

The problem isn't the model. The problem is that schema authoring is a design activity, and design requires iteration. You write a schema, run it against real documents, discover that "effective_date" returns null because the policy says "Policy Period: 03/15/2025 to 03/15/2026" and there's no standalone effective date field. You add a better description. You add a routing hint. You run it again. The field populates. You move on to the next failure.

This loop — write, test, diagnose, fix — is test-driven development for document extraction. And once you see it that way, schema development stops being mysterious and starts being methodical.

---

## The loop

Here's the actual workflow. No dashboard. No drag-and-drop form builder. A terminal, a schema file, and a sample document.

**Step 1: Start with the document.** Parse it to markdown first so you can see what the model will see:

```bash
koji process policy.pdf --parse-only
```

This produces `output/policy.md` — the raw text and structure that extraction will work against. Scanning it tells you what's actually in the document versus what you assume is there.

**Step 2: Write the first draft schema.** It doesn't need to be good. It needs to exist:

```yaml
name: commercial_policy
description: Commercial insurance policy

fields:
  policy_number:
    type: string
    required: true
    description: Policy number

  insured_name:
    type: string
    required: true
    description: Named insured

  effective_date:
    type: date
    description: Policy effective date

  expiration_date:
    type: date
    description: Policy expiration date

  premium:
    type: number
    description: Total premium amount
```

Five fields. No hints, no categories, no validation. This is the equivalent of writing a failing test — you know it won't extract everything correctly, but it establishes the contract.

**Step 3: Run it.**

```bash
koji extract output/policy.md --schema policy.yaml
```

Output:

```json
{
  "policy_number": "CPP-2024-089412",
  "insured_name": "Westfield Manufacturing LLC",
  "effective_date": null,
  "expiration_date": null,
  "premium": 24850
}
```

Two nulls. That's your red test.

**Step 4: Diagnose.** Open the parsed markdown. Search for the dates. You find this:

```
Policy Period: From 03/15/2025 To 03/15/2026 12:01 A.M. Standard Time
```

The model didn't map "Policy Period: From" to "effective_date" because the description didn't give it enough context. The dates are there — the schema just didn't ask for them clearly enough.

**Step 5: Fix the schema.**

```yaml
  effective_date:
    type: date
    description: >
      Policy effective date — the start of the policy period.
      Often labeled "Policy Period: From" or "Effective Date."
```

Run it again.

```json
{
  "effective_date": "2025-03-15",
  "expiration_date": "2026-03-15"
}
```

Green. Move on.

---

## Where it gets interesting

The first five fields are easy. The schema gets interesting when you hit fields that live in specific sections of a long document, or when the model hallucinates values that sound plausible but aren't in the source.

Consider extracting a coverage schedule from a 90-page commercial policy. The relevant table might be on page 12, but the model is also seeing endorsement language on page 47 that modifies those coverages. Without guidance, the extraction might return the base limit instead of the endorsed limit, or merge two different coverage tables.

This is where routing hints change the game:

```yaml
categories:
  keywords:
    declarations: ["declaration", "dec page", "named insured"]
    schedule: ["schedule of", "coverage schedule", "limits of"]
    endorsement: ["endorsement", "amendment", "this endorsement modifies"]

fields:
  coverages:
    type: array
    description: List of coverages with limits and deductibles
    items:
      type: object
      properties:
        coverage_name:
          type: string
        limit:
          type: string
        deductible:
          type: string
    hints:
      look_in: [schedule, declarations]
      signals: [has_tables, has_dollar_amounts]
```

The `hints.look_in` tells the router to only consider chunks from the declarations and schedule sections — not the endorsements, not the exclusions, not the 40 pages of policy conditions. The model sees less, hallucinates less, and returns what's actually on the schedule page.

Each time you add a hint, you run extraction again and check whether accuracy improved. Sometimes a hint helps. Sometimes it's too restrictive and the field that was populated before goes null. You adjust. This is the refactor step.

---

## Why this is TDD

The analogy isn't superficial. In traditional TDD:

- **Red:** Write a test that fails — define a field, run extraction, get null or a wrong value
- **Green:** Make it pass — improve the description, add a hint, adjust the type
- **Refactor:** Clean up — consolidate hints, remove unnecessary fields, add validation rules that catch regressions

The "test" is running `koji extract` against a real document. The "assertion" is checking whether the output matches what you can see in the source PDF. The "code under test" is the schema.

And just like real TDD, the discipline pays off at scale. A schema developed through five rounds of extract-inspect-fix against three representative documents will handle the next hundred documents reliably. A schema written in one shot by someone who glanced at a sample PDF will break on the first document that uses a slightly different layout.

---

## The schema is the product

Here's what makes this different from prompt engineering. When you iterate on a prompt, you're tuning prose — "please extract the effective date, which is usually near the top of the first page, sometimes labeled Policy Period." That works until the model updates and interprets "near the top" differently.

A schema is structured. The field type, the description, the routing hints, the validation rules — they're all discrete, testable components. When extraction breaks, you can trace exactly which part of the schema was responsible. "The date was null because `look_in` excluded the section where this particular policy puts its dates." That's debuggable. "The prompt wasn't specific enough" is not.

This matters when you're extracting thousands of documents. You don't need every schema iteration to be perfect. You need each failure to be diagnosable and each fix to be incremental.

---

## Locking it in

Once the schema handles your representative documents well, you lock in the results with snapshot tests:

```bash
koji test --schema policy.yaml --update
```

This saves the current extraction output as the expected baseline. From here on, any schema change that regresses a previously-correct field shows up as a test failure:

```bash
koji test --schema policy.yaml

✓ policy_number: CPP-2024-089412
✓ insured_name: Westfield Manufacturing LLC
✓ effective_date: 2025-03-15
✗ premium: expected 24850 but got 24500
```

The iterative loop discovered the schema. The snapshot test preserves it. If you change a hint to fix one document and it breaks three others, you know immediately — not after a customer reports bad data.

---

## What this looks like in practice

I rarely open the Koji console to build schemas. Most of the time, I don't even run the loop myself — my AI agent does.

I point Claude Code at a sample document and say "build me a schema for commercial insurance policies." The agent reads the parsed markdown, writes a first-draft schema, runs `koji extract`, reads the output JSON, compares it field-by-field against the source, diagnoses what went wrong, fixes the schema, and runs extraction again. Five or six cycles later, it hands me a schema that extracts the document type at 95%+ accuracy.

The agent isn't doing the extraction — that's the pipeline's job. The agent is doing the *schema engineering*: reading the document's structure, choosing the right field types, writing descriptions that match the document's actual language, adding routing hints when the model looks in the wrong section. It's doing the same diagnostic work a human would do, just faster.

A typical agent session looks like this:

```
Agent: Parsed policy.pdf → 47 pages. The declarations page has policy
       number, named insured, policy period, premium. Schedule of
       coverages starts on page 12. 6 endorsements follow.

Agent: Draft schema — 8 fields, no hints. Running extraction...

Agent: Results — 6/8 fields correct.
       ✗ effective_date: null (document uses "Policy Period: From")
       ✗ coverages: only 3 of 7 rows (chunks too narrow)
       Fixing: enriched date description, added max_chunks: 8 to
       coverages array. Re-extracting...

Agent: 8/8 fields correct. Locking in baseline with koji test --update.
```

Three iterations, maybe ten minutes. The schema is a plain YAML file I can review, diff, and commit. If I don't like a choice the agent made — say it used a `string` where I'd prefer an `enum` — I tell it, and it adjusts and re-extracts to verify nothing broke.

This is what schema development looks like when the feedback loop is tight enough for an AI agent to run it autonomously. The agent reads the docs, writes the config, tests it against real data, and iterates until the numbers are right. No GUI, no context-switching, no ambiguity about what changed and why.

We've packaged this workflow as a Claude Code skill — `/schema-tdd` — that ships with the Koji CLI. It fetches the latest schema authoring docs from getkoji.dev, then walks through the full loop: parse, draft, extract, diagnose, refine, test, push. If you're using Koji with Claude Code, it's the fastest way to get a production-ready schema.

```bash
koji extract sample.md --schema draft.yaml    # iterate locally
koji extract sample.md --schema draft.yaml    # iterate again
koji test --schema draft.yaml --update        # lock in the baseline
koji push --dir ./schemas/ -m "v1 commercial policy schema"
```

The whole process takes a few hours for a new document type — or a few minutes if the agent is driving. Not because the tool is fast, but because the feedback loop is tight. Write, run, see what broke, fix it. Every iteration is a commit. Every improvement is traceable.

---

## The console isn't obsolete

A natural question: if the agent loop is faster, why does the console exist?

Because schema development and document operations are different jobs for different people. The person *building* the extraction pipeline — choosing field types, tuning routing hints, diagnosing hallucinations — is better served by the agent loop. It's a programming task, and agents are good at programming tasks.

But the person *using* the pipeline — reviewing extracted data, spot-checking results, monitoring throughput — needs the dashboard. So does the customer who wants to see what's processing without learning YAML. The console is the operational interface. The CLI and agent loop are the engineering interface.

The point isn't that one replaces the other. It's that schema authoring is an engineering discipline, and it deserves engineering tools.

---

Document extraction isn't a model problem anymore. The models are good enough. It's a specification problem — telling the system precisely what to extract, from where, and how to validate it. Schema TDD is how you get that specification right, systematically, before your first customer document hits the pipeline. Whether you run the loop yourself or hand it to an agent, the discipline is the same: red, green, refactor, until the schema earns your trust.
