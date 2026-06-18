---
title: "We Don't Trust Our WHERE Clauses"
description: "In a multi-tenant system, the worst bug is the query that silently returns another customer's data. Here's how Koji makes that structurally impossible with Postgres row-level security — and the test that proves it holds."
date: 2026-06-11
author: "Frank Thomas"
tags: ["security", "multi-tenancy", "engineering"]
---

In a multi-tenant system, the worst bug isn't a crash. It's the query that quietly returns another customer's data because someone forgot `WHERE tenant_id = ?`. It doesn't throw. It doesn't log. It looks like a successful response. You find out when a customer emails you a screenshot of someone else's documents.

Every tenant-scoped query in Koji is one forgotten `WHERE` clause away from that. So we stopped relying on the `WHERE` clause. Here's the architecture, and — more importantly — the test that proves it holds.

---

## The problem with application-layer isolation

The default way to isolate tenants is a filter on every query: `WHERE tenant_id = $currentTenant`. It works until it doesn't. A new endpoint forgets it. A refactor drops it. A `JOIN` reintroduces a table whose filter lives somewhere else. A reporting query gets written in a hurry. There is no compiler that checks "did this query scope to the current tenant?" — it's a discipline, and disciplines fail at 3am under deadline.

The failure mode is the dangerous part: a missing filter doesn't error, it *over-returns*. The query succeeds with too many rows. Application-layer isolation makes the catastrophic failure (cross-tenant leak) silent and the safe failure (no rows) impossible. That's backwards.

## Push isolation into the database: Postgres RLS

Postgres Row-Level Security moves the filter out of the query and into the table. You attach a policy once:

```sql
ALTER TABLE schemas ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON schemas
  USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid);
```

Now *every* query against `schemas` — `SELECT`, `UPDATE`, `DELETE`, with or without a `WHERE` clause, through an ORM or raw SQL — is filtered by the database to rows matching the current tenant. The application can't forget, because the application isn't the one enforcing it anymore.

The key is `current_setting('app.current_tenant_id', true)`. That `true` is "missing_ok": if the setting was never set on this connection, it returns `NULL`. `NULL` never equals a real UUID, so an unset connection sees **zero rows**. That single design choice inverts the failure mode: forgetting to set the tenant is no longer a data-leak bug, it's an empty-result-set bug — loud, obvious, and caught the first time you run the feature in dev.

## One wrapper, set the tenant up front

Every handler that touches tenant data goes through one function:

```ts
export async function withRLS<T>(db, tenantId, fn): Promise<T> {
  if (!TENANT_ID_PATTERN.test(tenantId)) {
    throw new Error(`withRLS: refusing to set a non-UUID tenant id`);
  }
  return db.transaction(async (tx) => {
    await tx.execute(sql.raw(`SET LOCAL app.current_tenant_id = '${tenantId}'`));
    await tx.execute(sql.raw(`SET LOCAL ROLE app_user`));
    return fn(tx);
  });
}
```

Three things are doing real work here:

- **`SET LOCAL` inside a transaction.** `LOCAL` scopes the setting to this transaction — it's cleared automatically on commit or rollback and never leaks to the next query on a pooled connection. Connection pooling is exactly where naive "set the tenant on the session" approaches spring leaks; transaction-scoped settings close that hole.
- **The UUID regex guard.** We build the `SET LOCAL` statement by string interpolation (Postgres won't take a bind parameter there), so the input has to be trusted. The wrapper refuses anything that isn't a UUID before it reaches the SQL. The test suite fires `'; DROP TABLE schemas; --` at it and asserts it throws.
- **`SET LOCAL ROLE app_user`.** This one bit us, and it's the part most RLS write-ups miss. On managed Postgres (Neon, Supabase, and friends) the default role often has `BYPASSRLS`, which **silently disables every policy you wrote**. Your tests pass, your policies exist, and RLS does nothing. Switching to a non-superuser role inside the transaction forces the policies to actually evaluate.

The contract is simple: the only way to see rows is to name the tenant up front. There's no path that returns data without first declaring whose data it is.

## The part that matters: proving it

An isolation guarantee you haven't tested is a hope. And RLS is precisely the thing you cannot test with mocks — a mocked database returns whatever you tell it to. The only honest test spins up a real Postgres, applies the real policies, and tries to leak data across tenants.

So the RLS test suite uses [Testcontainers](https://node.testcontainers.org/modules/postgresql/) to boot a real Postgres 16, run the full migration stream (every `CREATE TABLE` plus every policy), create the non-superuser `app_user` role, seed two tenants, and then attack the boundary:

- A connection that **never** set a tenant returns zero rows. (Safe default holds.)
- `withRLS(tenantA)` and `withRLS(tenantB)` each see only their own rows — including queries with **no** explicit `tenant_id` filter, which is the entire point.
- The injection string is rejected.
- The `SET LOCAL ROLE app_user` path isolates *even when the connection role has `BYPASSRLS`* — and a control test confirms that without the role switch, the same connection sees everything (proving the switch is load-bearing, not decoration).
- Per-table isolation runs across schemas, projects, pipelines, jobs, and model endpoints, asserting zero ID overlap between what tenant A sees and what tenant B sees.

## The test that keeps it true as the schema grows

All of the above tests today's tables. The real risk in a multi-tenant system is *tomorrow's* table — the one someone adds in six months and forgets to attach a policy to. So the most valuable test in the suite doesn't test data at all. It introspects the database:

```ts
test("every table with a tenant_id column has an RLS policy or is explicitly global", async () => {
  const tablesWithTenantId = await db.execute(sql`
    SELECT table_name FROM information_schema.columns
    WHERE column_name = 'tenant_id' AND table_schema = 'public'
  `);
  const covered = /* tables that appear in pg_policies */;

  const intentionallyGlobal = new Set([
    "memberships",     // cross-tenant join, filtered application-side
    "parse_cache",     // shared by content hash; same file = same parse
    "model_catalog",   // global model catalog
    "background_jobs", // system-level job queue
  ]);

  const missing = tablesWithTenantId
    .filter(t => !covered.has(t) && !intentionallyGlobal.has(t));
  expect(missing).toEqual([]);
});
```

Add a tenant-scoped table without a policy and this test fails in CI. It can't be forgotten, because forgetting it is the failure condition. Every exception has to be named explicitly in the allowlist, with a comment explaining why it's safe to be global. Isolation stops being a thing engineers have to remember and becomes a thing the build enforces.

## Why this shape

The whole design is one idea applied three times: make the safe path the only path, and make the unsafe path *loud*.

- A forgotten tenant filter returns nothing, not everything.
- A new table without a policy fails the build, not production.
- A managed-Postgres `BYPASSRLS` footgun is closed by a role switch the tests prove is necessary.

You can't talk a team into never forgetting. You *can* build a system where forgetting is harmless and visible. For multi-tenant data, that's the difference between a security posture you describe in a sales call and one you can actually stand behind.

---

*Koji is an open-source, self-hosted document processing platform. The RLS wrapper and its test suite are in [github.com/getkoji/koji](https://github.com/getkoji/koji) under `packages/db`.*
