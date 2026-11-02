# Design principles

These are the rules I try to hold a backend to, and the specific problem each one prevents. Every one of them is implemented in the `Sql` folder and checked in `Tests/Run-Tests.sql`.

**Inbound data is a claim until it is validated.** Everything from outside lands in `inbound.records` first and only reaches `core` after something checks it. This prevents a malformed webhook or a bad import from corrupting a real record, and it means a rejected event can be replayed once the cause is fixed.

**Every inbound event has a sender id, and that id is unique.** The pair `(system_key, idempotency_key)` identifies an event. This prevents the usual duplicate: a provider retries a webhook, a script runs twice, and the same payment is counted twice.

**Money is an integer in minor units, with a currency code.** `150000` and `INR` rather than `1500.00`. This prevents rounding drift and the quiet bug where a number is read as rupees in one place and paise in another. Conversion is a display concern.

**A payment's identity is the provider's own id.** The unique index on `(provider, provider_payment_id)` makes replay safe at the database level, not just in application code that someone might bypass.

**A refund is a new row, never an edit.** The payment stays a record of what happened on the day. This prevents a payment total from changing under a report that was already sent, and it lets a trigger enforce that refunds never exceed what was paid.

**Unmatched money is kept and flagged, not dropped or guessed.** A payment with no application gets `needs_review = true`. This prevents both lost revenue and silent mismatches.

**Permission to contact lives in one place.** Consent and suppression are tables, and `compliance.can_send` is the only definition of "allowed". This prevents the case where one tool honours an opt-out and another does not. Suppression wins over consent.

**Sensitive access needs a grant with a reason and an expiry.** Roles describe a job. Grants describe a reason to look at something sensitive today. This prevents standing access that nobody remembers giving.

**The audit log cannot be edited, including by the people who run the database.** Triggers block UPDATE, DELETE and TRUNCATE. This prevents a log that is only trustworthy as long as nobody is under pressure to tidy it.

**Automation starts with no freedom to send.** Every agent and segment begins at level zero, enforced by a default, a CHECK constraint, and the absence of any UPDATE privilege on the column for ordinary roles. Raising it goes through one function that checks the caller is an owner and moves one level at a time. This prevents a misconfigured or misbehaving agent from emailing a large list before anyone has seen it work.

**Stopping everything is one update.** `control.runtime_controls` holds kill switches, and a missing switch counts as off. This prevents the situation where stopping a runaway send needs a code change and a deployment.

**Row-level security is on everywhere and denies by default.** A table with no policy returns nothing. This prevents the common mistake of adding a table, forgetting the policy, and exposing it. The service role bypasses RLS, so code that uses it stays on the server.
