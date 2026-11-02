-- Behaviour tests. Each check raises an exception on failure, so a failing
-- check stops the run with a non-zero exit code (psql ON_ERROR_STOP).

\set ON_ERROR_STOP on
\set QUIET on

create temp table test_ids (name text primary key, id uuid);
grant all on test_ids to public;

create function pg_temp.pass(p_name text) returns void
language plpgsql as $$ begin raise notice 'PASS  %', p_name; end $$;

create function pg_temp.fail(p_name text, p_detail text) returns void
language plpgsql as $$ begin raise exception 'FAIL  %: %', p_name, p_detail; end $$;

-- Fixed ids for the people in the scenario.
insert into test_ids values
    ('owner',   '00000000-0000-0000-0000-0000000000a1'),
    ('finance', '00000000-0000-0000-0000-0000000000b2'),
    ('nobody',  '00000000-0000-0000-0000-0000000000c3');

insert into access.role_assignments (staff_id, role) values
    ('00000000-0000-0000-0000-0000000000a1', 'owner'),
    ('00000000-0000-0000-0000-0000000000b2', 'finance');

------------------------------------------------------------------------
-- 1. Idempotent replay of an inbound event is a no-op
------------------------------------------------------------------------
do $$
declare
    a record; b record; n int;
begin
    select * into a from inbound.accept('provider_a', 'evt_1', '{"amount": 1500}');
    select * into b from inbound.accept('provider_a', 'evt_1', '{"amount": 1500}');

    select count(*) into n from inbound.records
    where system_key = 'provider_a' and idempotency_key = 'evt_1';

    if not a.is_new then perform pg_temp.fail('inbound replay', 'first call not new'); end if;
    if b.is_new then perform pg_temp.fail('inbound replay', 'replay reported as new'); end if;
    if a.record_id <> b.record_id then perform pg_temp.fail('inbound replay', 'ids differ'); end if;
    if n <> 1 then perform pg_temp.fail('inbound replay', 'row count ' || n); end if;
    perform pg_temp.pass('inbound replay creates one row, returns the same id');
end $$;

------------------------------------------------------------------------
-- 2. Payments are idempotent, and unmatched ones are flagged for review
------------------------------------------------------------------------
do $$
declare
    app uuid; p1 record; p2 record; p3 record; n int; flagged boolean;
begin
    insert into core.applications (applicant_ref, program_code)
    values ('applicant-001', 'PROG-X') returning id into app;

    select * into p1 from core.record_payment('provider_a', 'pay_1', app, 150000, 'INR');
    select * into p2 from core.record_payment('provider_a', 'pay_1', app, 150000, 'INR');
    select * into p3 from core.record_payment('provider_a', 'pay_2', null, 90000, 'INR');

    select count(*) into n from core.payments where provider_payment_id = 'pay_1';
    if n <> 1 or p2.is_new or p1.payment_id <> p2.payment_id then
        perform pg_temp.fail('payment replay', 'duplicate payment created');
    end if;
    perform pg_temp.pass('payment replay is a no-op');

    select needs_review into flagged from core.payments where id = p3.payment_id;
    if not flagged then perform pg_temp.fail('needs_review', 'unmatched payment not flagged'); end if;
    perform pg_temp.pass('payment with no application is flagged needs_review');

    -- Remember the matched payment for later tests.
    insert into test_ids values ('payment', p1.payment_id);
end $$;

------------------------------------------------------------------------
-- 3. Money rules: positive integers, upper-case currency
------------------------------------------------------------------------
do $$
begin
    begin
        perform core.record_payment('provider_a', 'pay_bad', null, 0, 'INR');
        perform pg_temp.fail('money check', 'zero amount accepted');
    exception when check_violation then null;
    end;
    begin
        perform core.record_payment('provider_a', 'pay_bad2', null, 100, 'inr');
        perform pg_temp.fail('money check', 'lower-case currency accepted');
    exception when check_violation then null;
    end;
    perform pg_temp.pass('zero amounts and lower-case currency codes are rejected');
end $$;

------------------------------------------------------------------------
-- 4. A refund is its own row, and cannot exceed the payment
------------------------------------------------------------------------
do $$
declare
    pay uuid := (select id from test_ids where name = 'payment');
    paid_before bigint; paid_after bigint; n int;
begin
    select amount_minor into paid_before from core.payments where id = pay;

    insert into core.refunds (payment_id, amount_minor, is_full, reason)
    values (pay, 50000, false, 'partial');

    select amount_minor into paid_after from core.payments where id = pay;
    select count(*) into n from core.refunds where payment_id = pay;

    if paid_before <> paid_after then
        perform pg_temp.fail('refund separate', 'payment row was changed');
    end if;
    if n <> 1 then perform pg_temp.fail('refund separate', 'refund row missing'); end if;
    perform pg_temp.pass('refund is a separate row, payment row untouched');

    begin
        insert into core.refunds (payment_id, amount_minor, is_full)
        values (pay, 100001, false);   -- 50000 + 100001 > 150000
        perform pg_temp.fail('refund cap', 'over-refund accepted');
    exception when check_violation then null;
    end;
    perform pg_temp.pass('refunds above the paid amount are rejected');
end $$;

------------------------------------------------------------------------
-- 5. Suppression blocks send eligibility, even with consent on file
------------------------------------------------------------------------
do $$
begin
    insert into compliance.consents (person_ref, channel, purpose)
    values ('person-1', 'email', 'program_updates'),
           ('person-2', 'email', 'program_updates');

    if not compliance.can_send('person-1', 'email', 'program_updates') then
        perform pg_temp.fail('consent', 'consented person blocked');
    end if;
    if compliance.can_send('person-3', 'email', 'program_updates') then
        perform pg_temp.fail('consent', 'person with no consent allowed');
    end if;
    if compliance.can_send('person-1', 'whatsapp', 'program_updates') then
        perform pg_temp.fail('consent', 'consent on one channel leaked to another');
    end if;

    insert into compliance.suppressions (person_ref, channel, reason)
    values ('person-1', 'email', 'asked to stop');

    if compliance.can_send('person-1', 'email', 'program_updates') then
        perform pg_temp.fail('suppression', 'suppressed person still allowed');
    end if;

    update compliance.consents set withdrawn_at = now()
    where person_ref = 'person-2';
    if compliance.can_send('person-2', 'email', 'program_updates') then
        perform pg_temp.fail('withdrawal', 'withdrawn consent still allowed');
    end if;
    perform pg_temp.pass('can_send honours consent, channel, suppression and withdrawal');
end $$;

------------------------------------------------------------------------
-- 6. The sensitive-access log is genuinely append-only
------------------------------------------------------------------------
do $$
declare
    staff uuid := '00000000-0000-0000-0000-0000000000b2';
    log_id bigint; n int;
begin
    -- Without a grant, access is refused and nothing is logged.
    begin
        perform access.log_sensitive_access(staff, 'view_contact_details', 'applicant', 'a-1');
        perform pg_temp.fail('grant required', 'access allowed without a grant');
    exception when insufficient_privilege then null;
    end;
    select count(*) into n from access.sensitive_access_log;
    if n <> 0 then perform pg_temp.fail('grant required', 'refused access was logged'); end if;

    -- A grant needs a real reason and a future expiry.
    begin
        insert into access.grants (staff_id, grant_key, reason, granted_by, expires_at)
        values (staff, 'view_contact_details', 'short', staff, now() + interval '1 day');
        perform pg_temp.fail('grant reason', 'short reason accepted');
    exception when check_violation then null;
    end;

    insert into access.grants (staff_id, grant_key, reason, granted_by, expires_at)
    values (staff, 'view_contact_details', 'Reconcile failed payment for applicant a-1',
            '00000000-0000-0000-0000-0000000000a1', now() + interval '1 day');

    log_id := access.log_sensitive_access(staff, 'view_contact_details', 'applicant', 'a-1');
    if log_id is null then perform pg_temp.fail('log write', 'no id returned'); end if;
    perform pg_temp.pass('access needs a live grant and is logged when it happens');

    begin
        update access.sensitive_access_log set subject_id = 'tampered' where id = log_id;
        perform pg_temp.fail('append-only', 'UPDATE succeeded');
    exception when insufficient_privilege then null;
    end;
    begin
        delete from access.sensitive_access_log where id = log_id;
        perform pg_temp.fail('append-only', 'DELETE succeeded');
    exception when insufficient_privilege then null;
    end;
    begin
        truncate access.sensitive_access_log;
        perform pg_temp.fail('append-only', 'TRUNCATE succeeded');
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.pass('log rejects UPDATE, DELETE and TRUNCATE, even for the table owner');

    -- An expired grant stops working.
    update access.grants set granted_at = now() - interval '2 days',
                             expires_at = now() - interval '1 day'
    where staff_id = staff;
    begin
        perform access.log_sensitive_access(staff, 'view_contact_details', 'applicant', 'a-2');
        perform pg_temp.fail('grant expiry', 'expired grant accepted');
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.pass('an expired grant no longer works');
end $$;

------------------------------------------------------------------------
-- 7. Agent autonomy starts at zero and only an owner can raise it
------------------------------------------------------------------------
do $$ begin
    insert into control.agent_autonomy (agent_key, segment) values ('email_agent', 'segment_a');
    if (select sending_level from control.agent_autonomy
        where agent_key = 'email_agent' and segment = 'segment_a') <> 0 then
        perform pg_temp.fail('autonomy default', 'not zero');
    end if;
    perform pg_temp.pass('new agent starts with sending autonomy 0');

    begin
        update control.agent_autonomy set sending_level = 9;
        perform pg_temp.fail('autonomy check', 'level 9 accepted');
    exception when check_violation then null;
    end;
    perform pg_temp.pass('CHECK constraint rejects levels outside 0 to 3');
end $$;

-- Ordinary signed-in user (finance role, not an owner).
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000b2';

do $$ begin
    begin
        update control.agent_autonomy set sending_level = 3;
        perform pg_temp.fail('autonomy privilege', 'ordinary role updated sending_level');
    exception when insufficient_privilege then null;
    end;
    begin
        insert into control.agent_autonomy (agent_key, segment, sending_level)
        values ('sneaky_agent', 'segment_a', 3);
        perform pg_temp.fail('autonomy privilege', 'ordinary role inserted level 3');
    exception when insufficient_privilege then null;
    end;
    begin
        perform control.raise_sending_autonomy('email_agent', 'segment_a', 1::smallint);
        perform pg_temp.fail('autonomy function', 'non-owner raised autonomy');
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.pass('non-owner cannot raise autonomy, by column privilege or by function');
end $$;

-- Owner, but the sending switch is still off.
set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$ begin
    begin
        perform control.raise_sending_autonomy('email_agent', 'segment_a', 1::smallint);
        perform pg_temp.fail('kill switch', 'raised while sending disabled');
    exception when check_violation then null;
    end;
    perform pg_temp.pass('even an owner cannot raise autonomy while sending is switched off');
end $$;

reset role;
update control.runtime_controls set bool_value = true where control_key = 'sending_enabled';

set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000a1';
do $$
declare lvl smallint;
begin
    perform control.raise_sending_autonomy('email_agent', 'segment_a', 1::smallint);
    select sending_level into lvl from control.agent_autonomy
    where agent_key = 'email_agent' and segment = 'segment_a';
    if lvl <> 1 then perform pg_temp.fail('owner raise', 'level is ' || lvl); end if;

    begin
        perform control.raise_sending_autonomy('email_agent', 'segment_a', 3::smallint);
        perform pg_temp.fail('step limit', 'jumped from 1 to 3');
    exception when check_violation then null;
    end;
    perform pg_temp.pass('owner can raise one level at a time once sending is enabled');
end $$;
reset role;

-- is_enabled treats a missing control as off.
do $$ begin
    if control.is_enabled('does_not_exist') then
        perform pg_temp.fail('kill switch', 'missing control treated as on');
    end if;
    perform pg_temp.pass('a missing control counts as disabled');
end $$;

------------------------------------------------------------------------
-- 8. Row-level security denies by default
------------------------------------------------------------------------
-- anon: no privileges at all.
set role anon;
do $$ begin
    begin
        perform count(*) from core.payments;
        perform pg_temp.fail('rls anon', 'anon could query core.payments');
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.pass('anon is refused outright');
end $$;
reset role;

-- authenticated with no role: allowed to query, sees nothing.
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000c3';
do $$
declare n int;
begin
    select count(*) into n from core.payments;
    if n <> 0 then perform pg_temp.fail('rls no role', 'saw ' || n || ' payments'); end if;
    select count(*) into n from compliance.suppressions;
    if n <> 0 then perform pg_temp.fail('rls no role', 'saw suppressions'); end if;
    begin
        perform count(*) from inbound.records;
        perform pg_temp.fail('rls inbound', 'authenticated reached inbound.records');
    exception when insufficient_privilege then null;
    end;
    begin
        perform count(*) from access.sensitive_access_log;
        perform pg_temp.fail('rls log', 'authenticated reached the access log');
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.pass('signed-in user with no role sees no rows, and cannot reach inbound or the log');
end $$;

-- finance role: sees payments, not compliance data.
set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000b2';
do $$
declare n int;
begin
    select count(*) into n from core.payments;
    if n < 2 then perform pg_temp.fail('rls finance', 'finance saw ' || n || ' payments'); end if;
    select count(*) into n from compliance.suppressions;
    if n <> 0 then perform pg_temp.fail('rls finance', 'finance saw suppressions'); end if;
    perform pg_temp.pass('finance role reads payments but not compliance tables');
end $$;
reset role;

-- service_role cannot weaken the audit log.
set role service_role;
do $$ begin
    begin
        delete from access.sensitive_access_log;
        perform pg_temp.fail('service_role log', 'service_role deleted log rows');
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.pass('service_role cannot delete from the audit log');
end $$;
reset role;

\echo
\echo ALL TESTS PASSED
