-- 03. Core entities and money
--
-- Money is stored as an integer count of minor units (paise, cents) plus a
-- currency code. Nothing is converted at rest.

create table core.applications (
    id            uuid primary key default gen_random_uuid(),
    applicant_ref text        not null,
    program_code  text        not null,
    created_at    timestamptz not null default now()
);

create table core.payments (
    id                  uuid primary key default gen_random_uuid(),
    provider            text    not null,
    provider_payment_id text    not null,
    application_id      uuid references core.applications (id),
    amount_minor        bigint  not null check (amount_minor > 0),
    currency            char(3) not null check (currency = upper(currency)),
    needs_review        boolean not null default false,
    source_record_id    uuid references inbound.records (id),
    received_at         timestamptz not null default now()
);

-- The provider's own id is the identity of a payment. A replayed webhook
-- cannot create a second row.
create unique index payments_provider_uq
    on core.payments (provider, provider_payment_id);

-- A refund is its own row. The payment row stays a historical fact.
create table core.refunds (
    id           uuid primary key default gen_random_uuid(),
    payment_id   uuid   not null references core.payments (id),
    amount_minor bigint not null check (amount_minor > 0),
    is_full      boolean not null,
    reason       text,
    refunded_at  timestamptz not null default now()
);

create index refunds_payment_idx on core.refunds (payment_id);

-- Refunds in total may never exceed what was paid.
create function core.refunds_within_payment() returns trigger
language plpgsql
as $$
declare
    v_paid     bigint;
    v_refunded bigint;
begin
    select amount_minor into v_paid
    from core.payments where id = new.payment_id
    for update;

    select coalesce(sum(amount_minor), 0) into v_refunded
    from core.refunds
    where payment_id = new.payment_id and id is distinct from new.id;

    if v_refunded + new.amount_minor > v_paid then
        raise exception 'refunds (%) would exceed payment (%)',
            v_refunded + new.amount_minor, v_paid
            using errcode = 'check_violation';
    end if;
    return new;
end;
$$;

create trigger refunds_within_payment
    before insert or update of amount_minor on core.refunds
    for each row execute function core.refunds_within_payment();

-- Record a payment idempotently. A payment that cannot be tied to an
-- application is kept, but flagged for a person to look at.
create function core.record_payment(
    p_provider            text,
    p_provider_payment_id text,
    p_application_id      uuid,
    p_amount_minor        bigint,
    p_currency            char(3),
    p_source_record_id    uuid default null
) returns table (payment_id uuid, is_new boolean)
language plpgsql
as $$
declare
    v_id uuid;
begin
    insert into core.payments (
        provider, provider_payment_id, application_id,
        amount_minor, currency, needs_review, source_record_id
    ) values (
        p_provider, p_provider_payment_id, p_application_id,
        p_amount_minor, p_currency, p_application_id is null, p_source_record_id
    )
    on conflict (provider, provider_payment_id) do nothing
    returning id into v_id;

    if v_id is not null then
        return query select v_id, true;
    else
        return query
            select p.id, false
            from core.payments p
            where p.provider = p_provider
              and p.provider_payment_id = p_provider_payment_id;
    end if;
end;
$$;
