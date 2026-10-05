---
title: "The Model Wrote 0"
description: "We tell the model to leave a missing number null. It writes 0 anyway. Here's the faithfulness gate we built to catch invented numbers, and why it makes misses honest without making them disappear."
date: 2026-07-16
author: "Frank Thomas"
tags: ["extraction", "faithfulness", "provenance", "llm"]
---

Here's a bug that looks like a data problem and isn't.

You extract a commercial property policy. The schema asks for each coverage's limit, deductible, and premium. Some of those values are printed on the page. Some aren't. The ones that aren't come back as `0`.

A `0` deductible is a real answer. It means "no deductible." A downstream system reading that field has no way to tell it apart from a deductible that was printed as `$0`. And the person reviewing the extraction can't tell either, because `$0` is a plausible number. A `null` says "we didn't find this." A `0` says "we found it, and it's zero." Only one of those is true.

---

## Where the zero came from

The obvious suspects were all in our own code.

**A normalization step coercing null to 0?** No. Koji's normalizers pass `null` through untouched.

**A schema default?** No. The schema didn't declare one.

**A strict JSON schema forcing the model to emit a number?** No. Our providers call the model in plain JSON mode (`response_format: { type: "json_object" }`), which guarantees valid JSON and nothing else. No field is forced to be a number. The model is free to return `null`.

**A prompt that didn't ask for null?** No. The extraction prompt says it in plain words: *"If a field is not present, use null."*

So the zero wasn't coming from us. The model was writing it. Given a numeric slot it couldn't fill, it filled it with a placeholder, `0` or sometimes an estimate, in spite of the instruction telling it not to.

This is worth sitting with, because the instinct is to fix it in the prompt. Make the instruction louder. Capitalize NULL. Add an example. We already had the instruction. The model read it and wrote `0` anyway. Any fix that depends on the model following that instruction more reliably is a fix that will work most of the time and fail silently the rest. That's the same failure we were trying to get rid of.

---

## The model already tells us where it looked

The fix came from something Koji was already asking the model for.

Every extraction prompt asks the model to cite its source: alongside each value, a `__source_text` with the exact verbatim text from the document where it found that value. We use that for provenance, to highlight the value on the page in the review UI. It's also exactly what you need to check whether a number is real.

The reasoning is simple. If the model read `$50,000` off the page, `50000` appears in the text it cited. If it invented a `0`, the `0` doesn't appear in that text, because it wasn't on the page.

So we added a pass that runs on the model's raw response, before anything else touches it, while every object still carries the text the model cited. For each numeric value, it checks whether that number actually occurs in the cited text. If it doesn't, the value is set to `null`.

That's the faithfulness gate. It shipped in Koji v0.80.0.

---

## Compare numbers, not strings

The tricky part is "actually occurs." A naive substring check is wrong in both directions. `"0"` is a substring of `"$50,000"`, so a fabricated zero would pass. And `9` isn't a substring of `"$9.00"` under some boundary rules, so a real value would get nulled.

So the gate doesn't compare strings. It pulls every complete number out of the cited text, parses each one, and compares numerically:

```typescript
/** Every complete numeric token in `text`, parsed to a Number. Grouping commas
 *  are stripped; whole comma/decimal-grouped runs are read as ONE number, so
 *  "$1,000,000" yields 1000000 (not 1, 000, 000) and "9.00" yields 9. */
function numbersInText(text: string): number[] {
  const out: number[] = [];
  for (const m of text.matchAll(/\d[\d,]*(?:\.\d+)?/g)) {
    const n = parseFloat(m[0].replace(/,/g, ""));
    if (!Number.isNaN(n)) out.push(n);
  }
  return out;
}

export function numericAnchoredInText(region: string, value: number | string): boolean {
  const target = typeof value === "number" ? value : parseFloat(String(value).replace(/[$,]/g, ""));
  if (Number.isNaN(target)) return false;
  return numbersInText(region).some((n) => Math.abs(n - target) < 1e-9);
}
```

That gets the cases right. `9` matches `"$9.00"`. `50000` matches `"$50,000"`. A fabricated `0` does not match `"$50,000"`, because the only number in that text is 50000. And `1000` doesn't match `"$1,000,000"`, because the comma-grouped run is read as one number.

Just as important, a `$0` that's really printed on the page survives. If the cited text says `| $0`, the number 0 is in it, and the value stays. The gate isn't against zeros. It's against numbers the model can't point to.

When the gate nulls a value, that field's confidence drops and the document routes to review instead of shipping a made-up number downstream.

---

## Deliberately conservative

A gate that nulls real values is worse than no gate, so the rules lean toward keeping things.

**Numbers only.** Strings and enums can legitimately differ from the page through normalization, aliases, or text that wraps across lines. Gating them would null correct values. Numbers have a clean way to compare, so we gate numbers and leave the rest alone.

**No citation, no verdict.** If the model didn't cite any source text for a value, there's nothing to check it against, so the value is kept. The gate only acts when it has evidence.

**Generic.** The gate walks numeric leaves and their cited text at any depth, including nested array rows. It doesn't know any field names or document types. It works the same on an invoice line item as on a coverage schedule.

To check that we weren't nulling real values, we ran an A/B on our receipts corpus: 91.7% with the gate, 91.7% on main without it. No regression. On the policy document that showed the problem, an end-to-end run with the gate nulled the fabricated deductible and premium zeros, kept the real limits, and kept a genuinely printed `$0`.

---

## The hole we left open, then closed

The first version had a known gap, and we wrote it down in the changelog instead of hiding it.

Inside an array, the model cited source text once per *row*, not once per field. So each number in a row was checked against the whole row's text. That leaves room for an invented number to slip through by matching a *different* field's real value in the same row. The case that worried us: a fabricated `deductible: 0` passes because the row also has a real `$0` printed for some other line.

The follow-up (v0.81.0) changed the prompt so that within each array item, the model also returns a `__field_source_text` map: for each of the row's own fields, the exact text for that one value. The gate now checks each value against its own field's citation. If a row only has the older row-level text, the gate falls back to row-level checking, so nothing that worked before breaks. The per-field citations are used during parsing and stripped before output. Receipts A/B again: 91.7% before and after.

There's still one gap, and it comes straight from the conservative rule. If the model invents a number and leaves that field out of its per-field citation map, the gate has nothing to check it against, so it keeps the value. The prompt tells the model to include a field in that map only if its value is actually printed, which is the behavior we want, but we're still trusting the model to leave the citation out *and* the value null. We chose this on purpose: nulling every uncited number would cost real values whenever the model skips a citation. It's a tradeoff, not a solved problem.

---

## Faithfulness is not recall

This is the part that's easiest to get wrong, so I'll be direct.

The gate makes the output **honest**. It does not make it **complete**. When the model fails to find a value, the gate turns a confident-looking `0` into an honest `null`. It never fills a value in. A field that was missing before the gate is still missing after it, it just stops pretending.

That matters because "we're getting zeros" and "we're missing values" feel like the same complaint, and they have different fixes. A zero the model invented is a faithfulness problem, and the gate handles it. A value that's printed on the page but never makes it into the output is a recall problem. The cause sits before the gate: the right text never reached the model, or the schema has no slot shaped to hold it. If a document lists many items and the schema has one field for them, the model has to pick one, and no gate after extraction will bring back the rest.

If you only measure accuracy, it's easy to confuse the two. Turning a fabricated `0` into `null` might not move a headline number at all, depending on how your scorer treats nulls. What actually changed is that a wrong answer became a visible gap. A reviewer sees a gap. Nobody sees a plausible wrong number.

---

## What to take from this

If you're extracting numbers with an LLM, some practical things:

**Assume the model will fill numeric slots it can't find.** Our prompt told the model to use null the whole time, and it still wrote `0`. Plan for the case where it doesn't listen.

**Ask for citations and check them.** If the model has to quote where each value came from, you can check its answer against its own evidence. That's a check in code, not a better-worded request, and it holds when the prompt doesn't.

**Compare numbers numerically.** Formatting differences (`$9.00` vs `9`, `$50,000` vs `50000`) will break a string match in both directions. Pull the numbers out and compare them as numbers.

**Make your gate conservative and write down its holes.** Gate the types you can check cleanly. Keep what you can't verify. Then list exactly what the gate can't catch, in the changelog, where users will see it.

**Don't let a faithfulness fix pass as a recall fix.** Nulling an invented value is the right thing to do, but it isn't finding the value. When someone reports wrong zeros, fix the zeros, then go find out separately why the real value never showed up.

The worst output an extraction system can produce isn't a blank. It's a confident, plausible, wrong number. The gate doesn't make Koji find more. It makes sure that when Koji doesn't know, it says so.
