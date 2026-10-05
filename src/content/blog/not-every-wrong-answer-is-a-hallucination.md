---
title: "Not Every Wrong Answer Is a Hallucination"
description: "When an extracted value is wrong, the reflex is to blame the model. Some of our worst wrong answers came from the PDF text layer instead: fonts that decode to glyph names, glyph ids, or text with the spaces in the wrong place. Here's what that looks like, how we detect it, and why confidence scoring can't save you."
date: 2026-07-23
author: "Frank Thomas"
tags: ["extraction", "parsing", "pdf", "engineering"]
---

When an extraction pipeline returns a wrong value, everyone has the same reflex: the model hallucinated. Swap the model, tighten the prompt, add a hint, move on.

Sometimes that's right. But over the last month we fixed a run of wrong values where the model did nothing wrong. It read exactly the text it was given and did a reasonable job with it. The problem was the text. The PDF looked fine on screen, but the characters our parser pulled out of it were garbage, and the model was working from that garbage.

This post covers four ways a PDF text layer goes bad, what each one did to extraction, and the detectors we now run before any model sees the text. The short version: **look at the parsed text the model actually received before you blame the model.**

---

## Failure 1: the font decodes to glyph names

A digital PDF doesn't store "the letter O." It stores a glyph from a font, plus (ideally) a ToUnicode CMap that tells a reader which character that glyph stands for. When the reader can't resolve the mapping, it has to emit *something*.

Docling's default backend, DoclingParseV2, fails to resolve the ToUnicode CMap for some custom-encoded Type1 fonts. When that happens it emits the raw glyph *name* in place of the character. Glyph names follow a convention where `uniXXXX` means "the character at Unicode code point XXXX," and `/uni004F` is U+004F, the capital letter O.

So a name like this (illustrative, not the real document):

```
OAKWOOD
```

comes out of the parser as something like:

```
/uni004FAKW/uni004F/uni004FD
```

Two bad things follow from that.

**The model guesses.** Given a name that's half escape codes, the model tries to reconstruct it and produces a plausible-looking wrong name. The commit for this fix records exactly that: the LLM "got garbage and guessed wrong values." From the outside, that is indistinguishable from a textbook hallucination.

**Or the model copies, and confidence goes up.** If the model passes the garbled string through verbatim, the value matches the source text exactly. Any confidence signal that checks "does this value appear in the document?" says yes, because it does appear, in the corrupted text. The same commit records the extraction coming back "with high confidence, since it copied the garbled string verbatim."

The PDF itself was fine. It has embedded text and a ToUnicode CMap, and pypdfium2 decodes it correctly. The bug was in one backend's font handling, and nothing else.

**The fix** ([koji#319](https://github.com/getkoji/koji/pull/319), shipped in 0.13.1): detect the garble and re-parse with Docling's `PyPdfiumDocumentBackend`, which resolves the ToUnicode CMap. We keep the rest of the Docling pipeline (layout, word bounding boxes) and only swap the backend that decodes the font. The detector is about as simple as code gets:

```python
_GLYPH_ESCAPE_RE = re.compile(r"/uni[0-9A-Fa-f]{4}")

def _has_glyph_garble(text: str) -> bool:
    return bool(_GLYPH_ESCAPE_RE.search(text or ""))
```

Real text essentially never contains `/uni` followed by four hex digits, so one match is enough to trigger the re-parse. The tests pin both directions: `/uni004F` fires, while `/unique` and `/uniZZZZ` don't.

---

## Failure 2: the font decodes to glyph *ids*

The second failure looked similar and turned out to be different.

Some PDFs (in our case, output from PScript5/Distiller with custom-encoded fonts) have a broken or missing ToUnicode CMap. The page renders perfectly, but the text layer has no recoverable characters at all. Docling's default backend emits the raw glyph ids as standalone escape tokens, `/14 /i255` and so on, for basically every word on the page.

Re-parsing with pypdfium doesn't help here. In our parse service, the code that handles this case says so: pypdfium "emits its own garbage." This isn't a font that one backend misreads. The characters just aren't in the file.

This case didn't produce a wrong value. It produced a crash. Escape-token garbage tokenizes much more densely than prose (about 3x, per the fix's commit message), and our extraction prompt budgeting estimated tokens from character count. A 151-page document came in far larger than estimated, and the model rejected it with `context_length_exceeded` at 285,896 tokens. The whole document failed.

**The fix** ([koji#529](https://github.com/getkoji/koji/pull/529), 0.79.1) has two parts:

- **Parse side:** `_looks_undecodable` fires when more than 10% of tokens are standalone `/NNN` or `/iNNN` escapes, and recovers by running full-page OCR, which reads the rendered glyphs instead of the broken text layer. We only accept the OCR output if it actually clears the detector.
- **Extract side:** the token estimator now weights digits and non-ASCII/control bytes as denser than prose, so it never undercounts the kind of content that overflows. If a model still reports a context-length error, extraction splits the group and retries instead of failing the document.

The same text layer then showed up on our fast in-process path, which uses pdfjs instead of Docling. There, pdfjs emitted the font's raw glyph ids as C0 control bytes and `0xFF` fill. Our existing corruption check missed it by a hair: on the failing document, the fragment ratio measured 0.54 against a 0.6 threshold, and the long-token ratio measured 0.06 against 0.1. The garbage was trusted, cached, and extracted into near-empty results. [koji#530](https://github.com/getkoji/koji/pull/530) (0.79.2) added a third check: if more than 5% of characters are non-printable, route the document to the heavy provider, which OCRs it.

---

## Failure 3: the characters are right, the spaces aren't

Some PDFs, especially ones with Type-3 or custom-encoded fonts, don't store spaces as space characters. The gap between words exists only in glyph positioning. Extractors that rebuild spacing from text-run geometry, including pdfjs and in some cases DoclingParseV2, drop it entirely. Whole phrases collapse into one token:

```
ACMEMANUFACTURINGCOMPANYLLC
```

(Illustrative; the real one was a company name.)

Every character is correct, so nothing about it looks like a decoding failure. But field extraction reads it as garbage, and does so without any error.

The signature is easy to measure once you know to look: an abnormal share of very long tokens. Real prose has almost none, since the longest common English words are around 20 characters and rare. On the failing document, about 21% of tokens were 20 characters or longer. On clean text the figure was about 0%.

**The fix** ([koji#497](https://github.com/getkoji/koji/pull/497), ported to our hosted parse service in [koji#498](https://github.com/getkoji/koji/pull/498)) also has two parts. Our corruption check gained a long-token check (more than 10% of tokens at 20+ characters), which pushes mashed pdfjs output to the heavy provider. And the parse service gained a poppler fallback: when Docling's own output shows the same signature, we re-extract with `pdftotext -bbox-layout`, which resolves spacing from each glyph's advance width. As with the other fallbacks, we only keep poppler's output if it actually fixes the problem.

---

## Failure 4: the corruption is on one page

The three checks above all run over the whole document, and that turned out to be a blind spot.

A 102-page document had two badly mangled pages, this time with the *opposite* spacing failure. pdfjs inserted spaces in the middle of words and left one-letter fragments behind, roughly like this (illustrative):

```
The Oa kw o od Ma nu fa c tu ri ng C o m pa ny
```

Averaged over 102 pages, the single-letter ratio for the whole document was 0.007, far below any threshold. So the document stayed on the fast path, and the model consumed the scrambled text without any signal that something was wrong. One extracted value was a website domain with an extra letter in it.

**The fix** ([koji#539](https://github.com/getkoji/koji/pull/539), 0.83.1) slides a 100-token window over the token stream and fires on the worst window: more than 15% lowercase single-letter fragments, with at least 4 distinct letters among them. Both guards matter. Excluding "a" and uppercase letters ignores real single-letter tokens, like row markers in tables and Y/N flags. The distinct-letter floor ignores decorative runs such as bullets that come out as `l l l l l`. Across 1,114 clean corpus documents, the new check produced zero false positives.

---

## Why confidence can't catch this

The first failure is the one I keep coming back to, because it breaks an assumption most extraction systems rely on.

A lot of extraction QA, ours included, works by grounding: if a value can be found in the source text, it's probably real; if it can't, it's suspect. That's a good check, and it catches a lot of fabrication. But it can only tell you whether the output is faithful to the source. It can't tell you whether the source is faithful to the document. When the parsed text is corrupted, a model that copies faithfully from it gets rewarded.

So corruption needs its own detection layer, separate from extraction QA and placed before it. Ours is deterministic on purpose. Each check is a regex or a ratio, cheap enough to run on every document, and measured against clean text. None of them asks a model whether the text looks okay.

The fallbacks share one rule: **a recovery is only accepted if it clears the detector.** A pypdfium re-parse that still has `/uni` escapes, an OCR pass that's still full of glyph ids, or a poppler extraction that's still mashed gets logged and dropped. We never swap one unverified text for another.

---

## Practical takeaways

If you run LLM extraction over PDFs, here's what we'd pass on:

1. **Debug from the parsed text, not the PDF.** The PDF on your screen is not what the model saw. Before you change a prompt or a model, pull up the exact text that went into the extraction call.
2. **Different extractors fail differently on the same file.** In these cases, pdfjs, DoclingParseV2, pypdfium, poppler, and OCR each read some file correctly that another one mangled. Having more than one engine available is what makes recovery possible.
3. **Detect corruption deterministically, and know each check's signature.** Glyph names (`/uniXXXX`), glyph ids (`/NNN`), control bytes, long tokens, and single-letter fragments are five different signatures. A check tuned for one will miss the others, which is how two of these bugs got through.
4. **Check locally, not just on average.** A whole-document ratio can hide one ruined page. Use a sliding window.
5. **Don't let grounding stand in for source quality.** Grounding checks that a value came from the text. It can't tell you the text is right.
6. **Budget tokens by content, not character count.** Garbage text tokenizes far more densely than prose. If your context guard assumes prose, garbage is exactly what will blow past it.
7. **Fix it in every parse path.** We run two parse services, self-hosted and hosted. One of these fixes first shipped to only one of them and needed a follow-up PR to reach the other. If you have more than one path, check each fix against all of them.

The model gets blamed for most wrong answers because it's the newest and least predictable part of the pipeline. Sometimes the blame is earned. But a model given `/uni004FAKW/uni004F/uni004FD` that returns the wrong name hasn't hallucinated. It was given bad text.
