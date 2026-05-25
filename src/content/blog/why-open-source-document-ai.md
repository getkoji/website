---
title: "Why Open Source for Document AI"
description: "We made Koji open source because the security claims that matter most are the ones you can verify yourself."
date: 2026-05-22
author: "Frank Thomas"
tags: ["open-source", "strategy"]
---

When we started building Koji, the first architectural decision wasn't about models or frameworks. It was about trust.

Document extraction processes the most sensitive data in any organization: insurance policies with coverage limits, contracts with confidential terms, medical records with diagnoses, financial filings with material non-public information. The tool that processes these documents sees everything.

We made Koji open source because the security claims that matter most are the ones you can verify yourself.

---

## The verification problem

Every document AI vendor makes the same claims:
- "Your data is never stored"
- "We don't train on your documents"
- "Processing is isolated per tenant"

These claims are unfalsifiable when the code is proprietary. You're trusting a vendor's word about what happens inside a black box. Your security team can audit the API contract (what goes in, what comes out) but not the implementation (what happens in between).

With open source, the security team can:
- Read the extraction pipeline and verify no data is exfiltrated
- Confirm no telemetry sends document content to third parties
- Verify tenant isolation at the code level, not just the marketing level
- Deploy a known, audited version rather than trusting automatic updates

This isn't theoretical. We've had security teams clone the repo, read the routing and extraction code, confirm the data flow matches our documentation, and approve deployment in a single review cycle. That review would take months with a proprietary vendor because it requires trust instead of verification.

---

## The local model shift

Two years ago, using a local LLM for extraction meant significant accuracy loss. GPT-4 was the only model that could reliably extract structured data from complex documents. That meant sending document content to OpenAI's API — a non-starter for many regulated industries.

That constraint is dissolving:
- **Llama 3** runs locally and handles structured extraction competently
- **Qwen 2.5** provides strong extraction in smaller parameter counts
- **Mistral** offers commercially licensable models optimized for enterprise workloads
- Inference frameworks (**Ollama**, **vLLM**, **TGI**) make local deployment trivial
- Hardware costs continue to drop — a single GPU that cost $40K in 2023 costs $15K today

The trajectory is clear: within 12-18 months, the accuracy gap between cloud and local models for structured extraction will be negligible. The extraction pipeline that only works with GPT-4o is a liability — it ties your data flow to an external provider permanently.

An open-source pipeline is model-agnostic by design. Swap `openai/gpt-4o-mini` for `ollama/llama3` in one configuration change. The routing, chunking, validation, confidence scoring — everything around the model — works identically regardless of which model does the extraction. When local models reach parity (and they will), you flip a switch. No migration, no re-architecture, no vendor negotiation.

---

## What "open source" means for document AI specifically

### Your schemas are yours

Extraction schemas in Koji are YAML files in a git repository. They define what fields to extract, how to route sections, what validation rules to apply, and what confidence thresholds to set. A team that spends six months perfecting their insurance policy schema — adding hints, expanding the test corpus, refining edge case handling — owns that work completely.

No lock-in, no export fee, no "we'll send you a CSV." The schemas are portable text files. If Koji disappears tomorrow, your schemas still work — they encode domain knowledge in a format any engineer can read.

### Your corpus is yours

The validation corpus — ground-truth documents with expected extraction outputs — is the most valuable artifact in any extraction deployment. It represents months of annotation work, edge case discovery, and accuracy improvement. In Koji, the corpus is a directory of JSON and markdown files. You own it, version it, and can use it to evaluate any extraction system, not just Koji.

### The pipeline is auditable

When extraction fails, you can trace exactly why:
1. Which sections were routed to which fields (and why — the scoring is deterministic)
2. What prompt the LLM received
3. What the LLM returned
4. How the response was validated

With a proprietary system, a failure is a black box: "the API returned the wrong value." With open source, you see the full chain and can fix the root cause — a missing schema hint, a routing gap, a prompt ambiguity.

---

## The business model question

"If the code is free, how do you make money?"

We don't sell the extraction engine. We sell the infrastructure that makes it production-grade at scale:

- **Koji Cloud** — managed hosting, so you don't run containers yourself
- **The platform** — multi-tenant management, team workspaces, pipeline orchestration, webhook integration, audit logging
- **Support and SLAs** — guaranteed response times, deployment assistance, schema development help
- **The form library** — pre-built schemas for common document types (ACORD forms, SEC filings, standard invoices) that save months of development

The engine is open source because extraction quality improves when more people use it, test it, and contribute edge cases to the corpus. The platform is commercial because orchestrating extraction at enterprise scale requires infrastructure that individual teams shouldn't have to build.

This model aligns incentives: we make money when customers succeed at scale, not when they're locked in. If the extraction quality degrades, customers can self-host and leave. That pressure keeps us honest about quality in a way proprietary lock-in never could.

---

## For regulated industries

If you're in insurance, healthcare, legal, or financial services, the open-source model addresses specific regulatory concerns:

**Data sovereignty (PIPEDA, GDPR, state insurance regs):** Self-host in your jurisdiction. Verify via source code that no data leaves your environment.

**Audit requirements:** Full audit trail of what was extracted, from what document, using which schema version, at what time. The pipeline's deterministic routing means you can reproduce any extraction decision.

**Vendor risk:** If Koji-the-company disappears, the extraction pipeline continues to run. Your schemas, corpus, and deployment are self-contained. No orphaned SaaS dependency.

**Model governance:** Choose which LLM processes your documents. Evaluate models yourself against your corpus. Switch providers without re-engineering the pipeline. Maintain an approved model list and enforce it at the configuration level.

---

## The long view

The document AI space is consolidating around two approaches:

1. **Proprietary platforms** that own the full stack (parsing, extraction, orchestration) behind an API. Fast to start, impossible to audit, expensive to scale, risky to depend on.

2. **Open infrastructure** that separates the extraction engine (commodity, improving fast) from the orchestration layer (where the value is). Slower to start, fully auditable, cost-effective at scale, zero vendor risk.

We built Koji as open infrastructure because we believe that's where the industry is going. The extraction engine is a solved problem — models will keep getting better and cheaper, and the pipeline around them is well-understood. The unsolved problems are domain-specific: how do you build schemas that capture an insurance company's specific document types? How do you maintain accuracy as forms change? How do you orchestrate extraction across 50 document types flowing in from 12 different sources?

Those problems are solved with configuration, not code. And configuration is most valuable when it's portable, testable, and owned by the team that builds it — not locked inside a vendor's proprietary format.

---

*Frank Thomas is the founder of [Koji](https://getkoji.dev), an open-source document extraction platform. The full extraction pipeline is available at [github.com/getkoji/koji](https://github.com/getkoji/koji).*
