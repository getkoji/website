---
title: "Where Your Documents Go During Extraction"
description: "The first question every security team asks when evaluating document AI: 'If I upload a policy PDF, who sees it?' Here's exactly what happens at every stage."
date: 2026-05-20
author: "Frank Thomas"
tags: ["security", "architecture"]
---

The first question every security team asks when evaluating document AI: "If I upload a policy PDF, who sees it?"

It's the right question. Insurance policies contain named insureds, coverage limits, premium amounts, and policy numbers. Medical records contain diagnoses and medications. Contracts contain terms that are confidential by definition. The security team's job is to ensure this data doesn't end up somewhere it shouldn't.

Here's exactly what happens to a document in Koji, at every stage.

---

## The document lifecycle

### Stage 1: Parse (document -> markdown)

The PDF is converted to structured markdown — headings, tables, paragraphs. This happens in the **parse service**, which runs in your environment (self-hosted) or in an isolated container (cloud).

**What leaves your environment:** Nothing. Parsing is a local operation using open-source libraries (docling, pdfplumber). No external API calls. No network requests. The PDF never leaves the machine it's parsed on.

**What's stored:** The parsed markdown is cached for performance (avoids re-parsing on retries or re-extraction). The source document is stored so users can preview it in the dashboard. Both live in your tenant's isolated storage, encrypted at rest, deletable on demand.

### Stage 2: Route (markdown -> relevant sections)

The parsed document is split into sections at heading boundaries. The router scores each section against each schema field using keyword matching, category labels, and structural signals. The top sections per field are selected.

**What leaves your environment:** Nothing. Routing is deterministic computation on the parsed text. No LLM calls, no external APIs, no network traffic. The scoring algorithm runs locally.

### Stage 3: Extract (sections -> structured JSON)

The selected sections are sent to a language model with a structured prompt. The model returns field values as JSON.

**What leaves your environment:** This is the only stage where data crosses a network boundary — and only when using a cloud LLM provider.

If you use **OpenAI's API**: the section text (not the full document — only the routed sections, typically 3-5 per field) is sent to OpenAI's API endpoint. Under OpenAI's Enterprise API terms (and the standard API terms as of March 2023), this data is **not used for training** and is **not retained beyond the request lifecycle** (30 days for abuse monitoring, zero-day retention with specific enterprise agreements).

If you use **Anthropic's API**: same principle. Anthropic's commercial terms explicitly state they do not train on API inputs.

If you use a **local model** (Llama, Qwen, Mistral via Ollama or vLLM): nothing leaves your environment. The extraction call goes to localhost. The entire pipeline runs air-gapped.

### Stage 4: Return (JSON -> your system)

The extracted JSON is returned to whatever called the extraction API — your application, a webhook, a queue processor. Koji does not store extraction results unless you explicitly configure a database backend.

**What's stored by Koji:** Extraction results are stored in your tenant's encrypted database partition for audit trail and review workflows. You own this data and can delete it at any time. Self-hosted deployments store everything in your own database.

---

## What the LLM sees vs. what you uploaded

A common misconception: "the LLM sees my entire 120-page policy."

It doesn't. The routing stage selects typically 3 sections per field — usually 2-5 pages of relevant content out of a 120-page document. The LLM sees:

- A heading like "Schedule of Limits"
- A table of coverage amounts
- Maybe the declarations page

It does not see the full endorsement stack, the 40 pages of boilerplate conditions, or the application that was stapled to the front. The routing stage's job is to minimize what the LLM sees while maximizing extraction accuracy.

This has a security benefit: even if the LLM provider were compromised, the exposure is a few pages of the most relevant content, not the entire document.

---

## Deployment models

### Self-hosted (air-gapped)

The entire Koji stack runs in your environment:
- Parse service (container)
- Extract service (container)
- API server
- Local LLM (Ollama, vLLM, or any OpenAI-compatible endpoint)

**Data flow:** Document -> your parse container -> your extract container -> your local LLM -> your API -> your application. Nothing leaves your network. No external API calls of any kind.

This is the model for organizations with strict data residency requirements (Canadian PIPEDA, GDPR, HIPAA, insurance regulatory requirements).

### Cloud with customer-managed keys

Koji Cloud runs the parse and route stages in isolated containers. For extraction, the platform uses **your** LLM API key — you bring your own OpenAI or Anthropic key, stored encrypted with a master key you control.

**Data flow:** Document -> our parse container -> our route logic -> your LLM provider (using your key) -> back to our API -> your application.

The LLM call goes directly to your provider account. We never see the API key in plaintext (it's encrypted at rest with your tenant's master key and decrypted only at call time in ephemeral memory).

### Fully managed (Koji Cloud)

Same as above, but we provide the LLM key. Simplest to set up, same provider guarantees about data retention and training.

---

## Encryption

- **In transit:** TLS everywhere. API -> parse, API -> extract, API -> LLM provider. No plaintext.
- **At rest:** Webhook secrets and API keys stored encrypted with `KOJI_MASTER_KEY` (AES-256). Document content is not persisted by default.
- **Tenant isolation:** Each customer's configuration, endpoints, and schemas are isolated by tenant ID with row-level security in the database.

---

## What we don't do

- **We don't train on your documents.** Koji is open source — you can verify this claim by reading the code. There is no telemetry that sends document content anywhere.
- **We don't log document content.** Operational logs contain metadata (document size, section count, elapsed time, field names) but never document text or extracted values.
- **You control document retention.** Source documents and parsed content are stored in your tenant's isolated partition for preview and re-processing. You can delete any document at any time — deletion is permanent, not soft-delete. Self-hosted deployments store everything in your own infrastructure.
- **We don't share LLM providers across tenants.** Each tenant configures their own model endpoint. There is no shared API key pool.

---

## For the security review

If you're evaluating Koji for an enterprise deployment, here's what we can provide:

- **Architecture diagram** showing data flow for your chosen deployment model
- **Source code access** — the extraction pipeline is open source, auditable
- **Deployment in your VPC** — self-hosted option means we never touch your data
- **Penetration test results** (upon request, under NDA)
- **Data processing addendum** matching your regulatory requirements

The short version: your documents are processed, not stored. The LLM sees sections, not full documents. Self-hosted means air-gapped. And because the pipeline is open source, you don't have to take our word for any of it.

---

*Frank Thomas is the founder of [Koji](https://getkoji.dev), an open-source document extraction platform. Questions about Koji's security architecture? [Get in touch](https://getkoji.dev/contact).*
