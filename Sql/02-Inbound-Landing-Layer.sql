-- 02. Inbound landing layer
--
-- Everything that arrives from outside (webhooks, form posts, imports) lands
-- here first. A row in this table is a claim, not a fact. It becomes a fact
-- only after something validates it and writes it into core.

create table inbound.records (
    id               uuid primary key default gen_random_uuid(),
    system_key       text        not null,   -- which sender, e.g. 'payment_provider_a'
    idempotency_key  text        not null,   -- the sender's own id for this event
    payload          jsonb       not null,
    received_at      timestamptz not null default now(),
    processed_at     timestamptz,
    rejected_at      timestamptz,
    rejected_reason  text,
    constraint records_one_outcome
        check (not (processed_at is not null and rejected_at is not null)),
    constraint records_reason_when_rejected
        check ((rejected_at is null) = (rejected_reason is null))
);

-- The same event delivered twice maps to the same row.
create unique index records_idempotency_uq
    on inbound.records (system_key, idempotency_key);

create index records_unprocessed_idx
    on inbound.records (received_at)
    where processed_at is null and rejected_at is null;

-- Accept an arrival. Returns the row id and whether this call created it.
-- A replay returns the original id with is_new = false and changes nothing.
create function inbound.accept(
    p_system_key      text,
    p_idempotency_key text,
    p_payload         jsonb
) returns table (record_id uuid, is_new boolean)
language plpgsql
as $$
declare
    v_id uuid;
begin
    insert into inbound.records (system_key, idempotency_key, payload)
    values (p_system_key, p_idempotency_key, p_payload)
    on conflict (system_key, idempotency_key) do nothing
    returning id into v_id;

    if v_id is not null then
        return query select v_id, true;
    else
        return query
            select r.id, false
            from inbound.records r
            where r.system_key = p_system_key
              and r.idempotency_key = p_idempotency_key;
    end if;
end;
$$;
