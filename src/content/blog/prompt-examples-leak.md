---
title: "Your Prompt Examples Are Leaking Into Your Output"
description: "A worked example in an extraction hint came back as an extracted value on a document it had nothing to do with. Here's how we caught it, the engine guard we shipped, the guard's own first-version bug, and the uncomfortable thing it revealed about our benchmark score."
date: 2026-07-30
author: "Frank Thomas"
tags: ["extraction", "prompts", "evaluation", "engineering"]
---

Every guide to prompting says the same thing: show the model an example. It works. Examples are the fastest way to get a model to understand what "the insured name" means on a messy page.

They also come back out. Not as a pattern the model learned from — as the literal answer, copied verbatim, on a document that has nothing to do with the example. We found this in our own extraction output, and the fix taught us something less comfortable about how we'd been measuring accuracy.

---

## The value that came from nowhere

Koji tracks provenance for every extracted value: where in the source text it came from. When it can't find one, the trace view says so — **"No source located."**

An `insured_name` came back with exactly that flag. The value looked right. It was a plausible organization name, correctly capitalized, the kind of thing that belongs in that field. It just wasn't anywhere in the document.

So where did it come from? It was sitting in the schema. The `insured_name` field had an `extraction_hint` explaining where the name usually sits on the page, and that hint used a worked example: *below the caption, the value is* "…". The model, in our case gpt-4o-mini, couldn't find a clean candidate in the chunks it was shown, and instead of returning null it returned the example from its own instructions.

It was worse than one bad field. The example names in those hints weren't made up. They had been lifted from real documents in our evaluation corpus, because when you're writing a hint, the natural thing is to paste the value you're looking at. Every one of them could show up as a wrong answer on some other document.

---

## Why this is the dangerous kind of wrong

A null routes to review. An obviously garbled value routes to review. A **plausible, well-formed, wrong** value goes straight through, because nothing about it looks wrong. It has the right shape, the right casing, the right length. It's also a real name that has nothing to do with the document.

That's what makes a prompt echo different from ordinary model error: the example was *chosen* to look like a correct answer. That was the whole reason to include it.

---

## The guard

The leak has a clean signature, and it's two signals together:

1. The value has **zero provenance**. It can't be located anywhere in the section text.
2. The value appears **verbatim** (whitespace- and case-normalized) in **that field's own hint text**.

Neither signal alone means anything. Reformatted values miss provenance all the time, and a hint example can genuinely appear in a document, in which case it has provenance and we keep it. When both are true, though, the model copied its instructions.

So the engine now checks for that conjunction after extraction. Matching scalars are nulled, matching array items removed, matching object properties nulled, and the affected fields are reported as `hint_leaks` in the extraction result and the trace. A short-value floor keeps it from firing on coincidental fragments like a state code. It's generic: the only thing it keys on is the schema's own hint text, with no field names and no document types. ([koji#460](https://github.com/getkoji/koji/pull/460), `api/src/extract/hint-leak.ts`.)

---

## The guard's own bug

The first version shipped and, on the next live validate run, the coverages score fell sharply. Every correctly mapped coverage code had been nulled.

That makes sense once you look at it. A `mapping` or `enum` field emits a **canonical** value the schema declares, like `general_liability`, not text copied from the page. Canonical values meet both leak conditions *by design*: they never appear verbatim in the source, and the hint mentions them because the hint is explaining the mapping. Our two-signal signature was right for transcribed text and wrong for anything the schema names itself.

The fix was to exempt enum/mapping leaves at every nesting level and keep guarding their transcribed siblings ([koji#463](https://github.com/getkoji/koji/pull/463)). It merged the same day, about twenty minutes after the original. The lesson isn't new, but it's worth repeating: a guard that nulls values is a guard that can null *correct* values, and the only reason we caught it quickly is that we ran it against a scored corpus before trusting it.

A later follow-up extended the guard to numbers. A worked premium amount in a hint came back as an extracted premium on documents that didn't contain it, and the model had reformatted it (dropped the comma and decimals), so a string match missed it. Numeric leaves are now compared by value, gated to four or more digits so small round examples aren't over-nulled ([koji#490](https://github.com/getkoji/koji/pull/490)).

---

## The other half of the fix: stop using real data in hints

The guard is a backstop. The real fix was in the schema: every real name, phone number, and address in the hints was replaced with a synthetic one.

```yaml
# Before: the example is a real value pasted from a corpus document
insured_name:
  type: string
  extraction_hint: >
    The named insured appears directly below the caption, e.g.
    "<A REAL ASSOCIATION NAME FROM A CORPUS DOC>". Do not return the
    management company.

# After: obviously synthetic, so any echo is self-evident
insured_name:
  type: string
  extraction_hint: >
    The named insured appears directly below the caption, e.g.
    "MAPLE RIDGE OWNERS ASSOCIATION" (illustrative). Do not return
    the management company.
```

(The "before" is shown with a placeholder on purpose; we're not going to reprint the real one.)

A synthetic example still teaches the model the layout. If it ever does leak, it's obviously fake, so a reviewer recognizes it, and the guard nulls it anyway.

---

## What the leak was hiding

This is the part that stung. When we sanitized the hints and re-ran the corpus, the score went **down**.

One document's `insured_name` had been "passing" only because its correct answer was sitting in the hint. The model wasn't finding the name on the page. It was reading it out of the prompt. With the real name gone, the honest result showed up: a routing miss, where the right section never reached the extractor. It's now a tracked bug instead of a green checkmark.

It wasn't just positive examples. Some hints carried **doc-specific negative examples**, things like "do not emit *this particular string*," written after looking at one corpus document's failure. Those suppressed false positives on exactly the documents they were written for. That isn't a general fix. It's coaching the eval. Removing them brought those false positives back, and they're tracked too.

The corpus is small, around ten documents for this schema, so we're not going to pretend the before-and-after numbers are precise. What we can say is which way they moved: the honest number is lower, and the higher one was partly an artifact of the hints containing answers.

---

## The rules we follow now

- **Hint examples are synthetic.** Never paste a value from a real document into a prompt. Make it obviously fake.
- **No negative examples written for one doc.** If a "do not emit X" names a string from one specific document, it's fixing that document's score, not the extractor.
- **Missing provenance is a signal, not noise.** A confident value with no source is the first thing to check, and the first place to look is your own prompt.
- **Any guard that nulls values gets a scored run before it's trusted.** Ours nulled every coverage code on its first day.

Examples in prompts are still worth it. Just assume anything you put in the prompt can end up in the output, and write the examples so you'd recognize them when they do.
