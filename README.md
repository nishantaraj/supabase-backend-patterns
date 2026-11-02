# Supabase backend patterns

A small, tested reference of the Postgres patterns I rely on when building the backend for a product that takes applications, payments and automated outreach: an inbound landing layer, money in minor units, refunds as their own rows, consent and suppression in the database, time-limited access grants, a log nobody can edit, kill switches, and automated agents that start with no authority to send.

This is an original reference. It is not the schema of any employer or client, it uses invented table names and contains no real data. It exists to show how I think about the problems, in code that runs.

## Run the tests

You need a plain Postgres 14 or newer and a role that can create databases and roles. The script creates a throwaway database, applies the SQL, runs the checks and drops it.

```bash
PGHOST=localhost PGUSER=postgres PGPASSWORD=yourpassword ./Tests/Run-Tests.sh
```

A passing run ends with `ALL TESTS PASSED`. A failing check stops the run with a non-zero exit code. Do not point this at a real Supabase project: `Tests/00-Supabase-Stubs-For-Local-Testing.sql` creates the roles and the `auth.uid()` function that Supabase already provides.

## Folder map

| Folder | What is in it |
|---|---|
| `Sql/` | The schema, in the order it should be applied. One file per concern. |
| `Tests/` | Stubs for Supabase's roles and `auth.uid()`, the behaviour tests, and the runner script. |
| `Docs/` | One page of design principles, each with the problem it prevents. |

| File | Pattern |
|---|---|
| `Sql/01-Extensions-And-Schemas.sql` | One schema per concern, nothing reachable by default |
| `Sql/02-Inbound-Landing-Layer.sql` | Arrivals are claims, deduplicated by sender id |
| `Sql/03-Core-Entities-And-Money.sql` | Minor units, idempotent payments, refunds as rows, needs-review flag |
| `Sql/04-Consent-And-Suppression.sql` | One `can_send` function that every sender must call |
| `Sql/05-Access-Control-And-Audit.sql` | Roles, expiring grants with reasons, append-only audit log |
| `Sql/06-Runtime-Controls-And-Agent-Autonomy.sql` | Kill switches, autonomy starting at zero, one guarded door to raise it |
| `Sql/07-Row-Level-Security.sql` | RLS on and forced everywhere, deny by default |

## Limits

The tests show the behaviour on a local Postgres. They do not replace a security review of a real project: check the grants on your own functions, review any `SECURITY DEFINER` function for `search_path`, and run Supabase's database advisors before going live.
